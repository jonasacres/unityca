#!/usr/bin/ruby

require 'sinatra'
require 'open3'

UNITYCA_DIR        = "." # directory for process execution; other paths are relative to this
HOST_CA_KEY        = "keys/host_ca_key" # path to CA file for signing host keys; must be passwordless!
USER_CA_KEY        = "keys/user_ca_key" # path to CA file for signing user keys; must be passwordless!
SCRIPTS_FOLDER     = "scripts"     # path to folder with client scripts (everything here is served as GET /scripts/*)
HOST_CERT_VALIDITY = "+1w" # passed as ssh-keygen -V argument, eg. "+52w" for 1-year

Dir.chdir(UNITYCA_DIR)

set :port, 8080
set :bind, "0.0.0.0"
set :root, File.expand_path(UNITYCA_DIR)

configure do
  mime_type :certificate, 'text/plain'
  mime_type :public_key, 'text/plain'
end

not_found do
  ""
end

helpers do
  def valid_signature?(msg, sig, key, identity, hostnames)
    rng = rand(10**9)
    sigpath     = "/tmp/unityca.tmpsig.#{rng}"
    msgpath     = "/tmp/unityca.tmpmsg.#{rng}"
    signerspath = "/tmp/unityca.tmpsigners.#{rng}"

    begin
      IO.write(sigpath, sig)
      IO.write(msgpath, msg)
      IO.write(signerspath, identity + " " + key + "\n")

      status = Open3.popen3(
        "ssh-keygen",
        "-Y", "verify",
        "-n", hostnames.join(","),
        "-s", sigpath,
        "-I", identity,
        "-f", signerspath
      ) do |stdin, stdout, stderr, thr|
        stdin.write(msg)
        stdin.close
        stderr.close
        stdout.close
        thr.value
      end

      return status == 0
    ensure
      # [sigpath, msgpath, signerspath].each { |p| File.unlink(p) rescue nil }
    end
  end

  def reconstitute_signature(signature)
    line_length = 70.0
    num_lines = (signature.length / line_length).ceil
    lines = num_lines.times.map { |n| signature[line_length*n ... line_length*(n+1)] }
    ["-----BEGIN SSH SIGNATURE-----", *lines, "-----END SSH SIGNATURE-----"] .join("\n")
  end

  def parse_request!(reqbody)
    puts reqbody
    hash = Digest::SHA256.hexdigest(reqbody)
    signed, unsigned = reqbody.split("\n\n")
    halt 400, "need signed and unsigned section" unless signed && unsigned

    signed_lines   = signed.split("\n")
    unsigned_lines = unsigned.split("\n")

      signed_lines.count >= 4 or halt 400, "expect >= 4 lines in signed section"
    unsigned_lines.count >= 2 or halt 400, "expect >= 2 lines in unsigned section"
    signed_lines[0].downcase.match(/^[a-z0-9,\-\.]+$/) or halt 400, "expect valid hostname in first line of signed section"
    signed_lines[1].match(/^\d+$/) or halt 400, "expect valid millisecond timestamp in second line of signed section"

    hostnames = signed_lines[0].split(",")

    parsed = {
      hostname:       hostnames.first,
      hostnames:      hostnames,
      identity:       hostnames.first,
      timestamp:      Time.at(signed_lines[1].to_i*1e-3),
      new_pubkey:     signed_lines[2],
      old_pubkey:     signed_lines[3],
      new_pubkey_sig: reconstitute_signature(unsigned_lines[0]),
      old_pubkey_sig: reconstitute_signature(unsigned_lines[1]),
      new_type:       signed_lines[2].split(" ").first.split("-")[1],
      old_type:       signed_lines[3].split(" ").first.split("-")[1],
    }

    parsed[:old_type] == parsed[:new_type] && parsed[:new_type] == "ed25519" or halt 400, "only ed25519 supported" # security issues in supporting multiple key types; address these before relaxing this requirement
    valid_signature?(signed, parsed[:new_pubkey_sig], parsed[:new_pubkey], parsed[:identity], parsed[:hostnames]) or halt 400, "invalid newkey signature"
    valid_signature?(signed, parsed[:old_pubkey_sig], parsed[:old_pubkey], parsed[:identity], parsed[:hostnames]) or halt 400, "invalid oldkey signature"

    parsed
  end

  def current_host_key(hostname, type)
    path = "hosts/#{hostname}/#{type}.pub"
    File.exists?(path) ? IO.read(path).strip : nil
  end

  def acceptable?(parsed)
    parsed[:hostnames].each do |hostname|
      current_key = current_host_key(hostname, parsed[:new_type])
      return false unless [nil, parsed[:old_pubkey], parsed[:new_pubkey]].include?(current_key)
    end

    true
  end

  def grant_certificate(parsed)
    path_new = "hosts/#{parsed[:hostname]}/ssh_host_#{parsed[:new_type]}_key.pub"
    path_old = "hosts/#{parsed[:hostname]}/ssh_host_#{parsed[:old_type]}_key.pub"

    IO.write(path_new, parsed[:new_pubkey])
    `ssh-keygen -h -s "#{HOST_CA_KEY}" -I "#{parsed[:identity]}" -n "#{parsed[:hostnames]}" -V "#{HOST_CERT_VALIDITY}" "#{path}"`
    `rm -f "#{secondary_path_old}"` unless secondary_path_new == secondary_path_old

    parsed[:hostnames][1..-1].each do |hostname|
      secondary_path_new = "hosts/#{hostname}/ssh_host_#{parsed[:new_type]}_key.pub"
      secondary_path_old = "hosts/#{hostname}/ssh_host_#{parsed[:old_type]}_key.pub"
      `cp "#{path_new}" "#{secondary_path_new}"`
      `rm -f "#{secondary_path_old}"` unless secondary_path_new == secondary_path_old
    end

    IO.read(path_new)
  end
end

get '/host.sh' do
  redirect to("/scripts/host-init.sh")
end

post '/host' do
  request.body.rewind
  parsed = parse_request!(request.body.read)
  if acceptable?(parsed) then
    content_type :certificate
    grant_certificate(parsed)
  else
    IO.write("#{parsed[:hostname]}/#{parsed[:new_pubkey_type]}.pub.proposed", parsed[:new_pubkey])
    halt 409
  end
end

get '/host_ca.pub' do
  content_type :public_key
  send_file(HOST_CA_KEY + ".pub")
end

get '/user_ca.pub' do
  content_type :public_key
  send_file(USER_CA_FILE + ".pub")
end

get '/scripts/:script' do |script|
  path = File.join(SCRIPTS_FOLDER, script)
  halt 404 unless File.readable?(path)
  send_file(path)
end
