require 'open3'
require 'pathname'

project_path = ENV["AC_XCODEPROJ_PATH"] || ""
repository_path = ENV["AC_REPOSITORY_DIR"]

cocoapods_version = (ENV["AC_COCOAPODS_VERSION"] != nil && ENV["AC_COCOAPODS_VERSION"] !="") ? ENV["AC_COCOAPODS_VERSION"] : nil

project_dir_path = ""
if repository_path
    unless project_path.to_s.strip.empty?
        project_dir_path = (Pathname.new repository_path).join(File.dirname(project_path)) : File.dirname(project_path)
    end
end

unless File.exist?(cocoapods_podfile_path)
    puts "Podfile does not exists."
    exit 0
end

if !project_path.to_s.strip.empty? && File.extname(project_path) != ".xcodeproj"
    puts "Project extension must be xcodeproj."
    exit 0
end

def runCommand(command)
    puts "@@[command] #{command}"
    unless system(command)
      exit $?.exitstatus
    end
end

if cocoapods_version.nil?
  if File.exist?(cocoapods_podfilelock_path)
    versionArray = File.read(cocoapods_podfilelock_path).scan(/(?<=COCOAPODS: )(.*)/)[0]
    if versionArray && versionArray[0]
      cocoapods_version = versionArray[0]
      puts "Podfile.lock version = #{cocoapods_version}"
      if `which rbenv`.empty?
        runCommand("sudo gem install cocoapods -v #{cocoapods_version} --no-document")
      else
        runCommand("gem install cocoapods -v #{cocoapods_version} --no-document")
      end
    end
  end
else
  puts "Cocoapods version = #{cocoapods_version}"
  if `which rbenv`.empty?
    runCommand("sudo gem install cocoapods -v #{cocoapods_version} --no-document")
  else
    runCommand("gem install cocoapods -v #{cocoapods_version} --no-document")
  end
end

if cocoapods_version.nil?
    runCommand("pod --version")
end

Dir.chdir(project_dir_path) do
    command = "pod"
    unless cocoapods_version.nil?
      command += " _#{cocoapods_version}_"
    end
    command += " deintegrate"
    runCommand(command)
end

exit 0
