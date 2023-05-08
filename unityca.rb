#!/usr/bin/env ruby

require 'sinatra'
require 'open3'


UNITYCA_DIR        = File.dirname(__FILE__) # directory for process execution; other paths are relative to this
HOST_CA_KEY        = "keys/host_ca_key" # path to CA file for signing host keys; must be passwordless!
USER_CA_KEY        = "keys/user_ca_key" # path to CA file for signing user keys; must be passwordless!
REVOKED_DIR        = "revoked/"
SCRIPTS_FOLDER     = "scripts"     # path to folder with client scripts (everything here is served as GET /scripts/*)
HOST_CERT_VALIDITY = "+1w" # passed as ssh-keygen -V argument, eg. "+52w" for 1-year
PIDFILE            = "unityca.pid"

Dir.chdir(UNITYCA_DIR)
IO.write(PIDFILE, Process.pid)
at_exit { (File.unlink(PIDFILE) rescue nil) if Process.pid == IO.read(PIDFILE) }

Dir.mkdir(REVOKED_DIR) unless File.exist?(REVOKED_DIR)

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
  def logmsg(msg, caller_offset=0)
    ref = caller[caller_offset]
    file, line, func = ref.split(":")

    printf("%s: %s:%d -- %s\n",
      Time.now.strftime("%Y-%m-%d %H:%M:%S"),
      file,
      line,
      msg);
  end

  def reject(status, msg)
    logmsg("Rejecting with #{status}: #{msg}", 1)
    halt status, msg
  end

  def valid_signature?(msg, sig, key, identity, hostnames)
    rng = rand(10**9)
    sigpath     = "/tmp/unityca.tmpsig.#{rng}"
    msgpath     = "/tmp/unityca.tmpmsg.#{rng}"
    signerspath = "/tmp/unityca.tmpsigners.#{rng}"

    begin
      IO.write(sigpath, sig)
      IO.write(msgpath, msg)
      IO.write(signerspath, identity + " " + key.split(" ")[0..1].join(" ") + "\n")
      cmdline = %Q{cat "#{msgpath}" | ssh-keygen -Y verify -n "#{hostnames.join(",")}" -s "#{sigpath}" -I "#{identity}" -f "#{signerspath}"}
      %x{#{cmdline}}
      $?.to_i == 0
    ensure
      [sigpath, msgpath, signerspath].each { |p| File.unlink(p) rescue nil }
    end
  end

  def reconstitute_signature(signature)
    line_length = 70.0
    num_lines = (signature.length / line_length).ceil
    lines = num_lines.times.map { |n| signature[line_length*n ... line_length*(n+1)] }
    ["-----BEGIN SSH SIGNATURE-----", *lines, "-----END SSH SIGNATURE-----", ""] .join("\n")
  end

  def parse_request!(reqbody)
    logmsg reqbody
    hash = Digest::SHA256.hexdigest(reqbody)
    signed, unsigned = reqbody.split("\n\n")
    reject 400, "need signed and unsigned section" unless signed && unsigned

    signed += "\n"
    signed_lines   = signed.split("\n")
    unsigned_lines = unsigned.split("\n")

      signed_lines.count >= 4 or reject 400, "expect >= 4 lines in signed section"
    unsigned_lines.count >= 2 or reject 400, "expect >= 2 lines in unsigned section"
    signed_lines[0].downcase.match(/^[a-z0-9,\-\.]+$/) or reject 400, "expect valid hostname in first line of signed section"
    signed_lines[1].match(/^\d+$/) or reject 400, "expect valid millisecond timestamp in second line of signed section"

    hostnames = signed_lines[0].split(",")

    parsed = {
      hostname:       hostnames.first,
      hostnames:      hostnames,
      identity:       "unityca-#{signed_lines[1]}@#{hostnames.first}",
      timestamp:      Time.at(signed_lines[1].to_i),
      new_pubkey:     signed_lines[2],
      old_pubkey:     signed_lines[3],
      new_pubkey_sig: reconstitute_signature(unsigned_lines[0]),
      old_pubkey_sig: reconstitute_signature(unsigned_lines[1]),
      new_type:       signed_lines[2].split(" ").first.split("-")[1],
      old_type:       signed_lines[3].split(" ").first.split("-")[1],
    }

    parsed[:old_type] == parsed[:new_type] && parsed[:new_type] == "ed25519" or reject 400, "only ed25519 supported" # security issues in supporting multiple key types; address these before relaxing this requirement
    valid_signature?(signed, parsed[:new_pubkey_sig], parsed[:new_pubkey], parsed[:identity], parsed[:hostnames]) or reject 400, "invalid newkey signature"
    valid_signature?(signed, parsed[:old_pubkey_sig], parsed[:old_pubkey], parsed[:identity], parsed[:hostnames]) or reject 400, "invalid oldkey signature"

    parsed
  end

  def current_host_key(hostname, type)
    path = "hosts/#{hostname}/ssh_host_#{type}_key.pub"
    File.exist?(path) ? IO.read(path).strip : nil
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
    cert_new = path_new[0..-5] + "-cert.pub"
    cert_old = path_old[0..-5] + "-cert.pub"

    `mkdir -p "#{File.dirname(path_new)}"`
    IO.write(path_new, parsed[:new_pubkey])
    `ssh-keygen -h -s "#{HOST_CA_KEY}" -I "#{parsed[:identity]}" -n "#{parsed[:hostnames].join(",")}" -V "#{HOST_CERT_VALIDITY}" "#{path_new}"`
    `rm -f "#{path_old}"` unless path_new == path_old
    `rm -f "#{cert_old}"` unless cert_new == cert_old

    parsed[:hostnames][1..-1].each do |hostname|
      secondary_path_new = "hosts/#{hostname}/ssh_host_#{parsed[:new_type]}_key.pub"
      secondary_path_old = "hosts/#{hostname}/ssh_host_#{parsed[:old_type]}_key.pub"
      secondary_cert_new = secondary_path_new[0..-5] + "-cert.pub"
      secondary_cert_old = secondary_path_old[0..-5] + "-cert.pub"

      `mkdir -p "#{File.dirname(secondary_path_new)}"`
      `cp "#{path_new}" "#{secondary_path_new}"`
      `cp "#{cert_new}" "#{secondary_cert_new}"`
      `rm -f "#{secondary_path_old}"` unless secondary_path_new == secondary_path_old
      `rm -f "#{secondary_cert_old}"` unless secondary_cert_new == secondary_cert_old
    end

    IO.read(path_new[0..-5] + "-cert.pub")
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
    IO.write("hosts/#{parsed[:hostname]}/ssh_host_#{parsed[:new_type]}_key.pub.proposed", parsed[:new_pubkey])
    reject 409, "Public key does not match existing key on file"
  end
end

get '/host_ca.pub' do
  content_type :public_key
  send_file(HOST_CA_KEY + ".pub")
end

get '/user_ca.pub' do
  content_type :public_key
  send_file(USER_CA_KEY + ".pub")
end

get '/scripts/:script' do |script|
  path = File.join(SCRIPTS_FOLDER, script)
  reject 404, "Unable to locate requested script: #{script}" unless File.readable?(path)
  send_file(path)
end

get '/revoked' do
  # putting a public key or certificate into the revocation directory should cause it to be revoked
  all_revoked = Dir.glob(File.join(REVOKED_DIR, "*")).map do |file|
    IO.read(file)
      .split("\n")
      .select { |line| line.match(/^ssh-[a-zA-Z0-9\-\.@]+ [A-Za-z0-9\+\/]+( [a-zA-Z0-9\-\.\@]+)$/) }
  end.flatten

  # list all keys sorted by domain
  all_revoked.sort_by { |line| line.split(" ").last.split("@")[1..-1].reverse.join(".") }
  all_revoked.join("\n")
end
