# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'pathname'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)

# If the top-level guard is ever lost, requiring main.rb runs the step and its
# `exit 0` would end this suite with a false green. Fail loudly instead.
begin
  require MAIN_RB
rescue SystemExit => e
  abort "main.rb ran its step on require (exit #{e.status}); top-level code must stay inside `if __FILE__ == $PROGRAM_NAME`."
end

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m",  # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Build a minimal CocoaPods project tree inside `root`:
#   <root>/<subdir>/MyApp.xcodeproj   (directory, as Xcode creates it)
#   <root>/<subdir>/Podfile
#   <root>/<subdir>/Podfile.lock      (only when `lock` is given)
# Returns the absolute path of the project directory.
def build_project(root, subdir: 'app', project: 'MyApp.xcodeproj', podfile: true, lock: nil)
  dir = subdir.empty? ? root : File.join(root, subdir)
  FileUtils.mkdir_p(File.join(dir, project))
  File.write(File.join(dir, 'Podfile'), "platform :ios, '13.0'\n") if podfile
  File.write(File.join(dir, 'Podfile.lock'), lock) if lock
  dir
end

# Podfile.lock content as CocoaPods writes it.
def podfile_lock(version)
  <<~LOCK
    PODS:
      - Alamofire (5.6.4)

    PODFILE CHECKSUM: 0123456789abcdef

    COCOAPODS: #{version}
  LOCK
end

# Create stub `pod`, `gem`, `sudo` and `which` executables so the subprocess
# script never touches the real toolchain (and `sudo` never escalates).
# Each stub logs its arguments and working directory to stdout. It exits with
# STUB_<NAME>_EXIT when its arguments contain STUB_<NAME>_FAIL_ON.
# `which rbenv` succeeds only when STUB_RBENV is set.
# Returns the directory to prepend to PATH.
def build_stub_bin(root)
  bin = File.join(root, 'stubbin')
  FileUtils.mkdir_p(bin)
  %w[pod gem sudo].each do |name|
    up = name.upcase
    File.write(File.join(bin, name), <<~SH)
      #!/bin/sh
      echo "STUB-#{name} $* [cwd=$(pwd -P)]"
      if [ -n "$STUB_#{up}_FAIL_ON" ]; then
        case "$*" in
          *"$STUB_#{up}_FAIL_ON"*) exit "${STUB_#{up}_EXIT:-1}" ;;
        esac
      fi
      exit 0
    SH
  end
  File.write(File.join(bin, 'which'), <<~SH)
    #!/bin/sh
    if [ "$1" = "rbenv" ] && [ -n "$STUB_RBENV" ]; then
      echo "#{bin}/rbenv"
      exit 0
    fi
    exit 1
  SH
  Dir.glob(File.join(bin, '*')).each { |f| FileUtils.chmod(0o755, f) }
  bin
end

# Directory where child processes drop their coverage snapshots, so the report
# reflects the guarded top-level blocks as well as the in-process functions.
COVERAGE_DIR = Dir.mktmpdir('cocoapods_deintegrate_cov')

# Preloaded into every child with `ruby -r<helper> main.rb`, which keeps
# main.rb as $PROGRAM_NAME so its top-level guards still fire.
COVERAGE_HELPER = File.join(COVERAGE_DIR, 'cov_helper.rb')
File.write(COVERAGE_HELPER, <<~RUBY)
  require 'coverage'
  Coverage.start
  at_exit do
    dir = ENV['AC_TEST_COVERAGE_DIR']
    next if dir.nil? || dir.empty?

    result = begin
      Coverage.result(stop: false, clear: false)
    rescue ArgumentError
      Coverage.result
    end
    target = result.keys.find { |p| p.to_s.end_with?('main.rb') }
    next if target.nil?

    counts = result[target].map { |c| c.nil? ? '-' : c }.join(',')
    File.write(File.join(dir, "cov-\#{Process.pid}.txt"), counts)
  end
RUBY

# Merge every child snapshot into a single line-count array.
def subprocess_coverage
  Dir.glob(File.join(COVERAGE_DIR, 'cov-*.txt')).each_with_object([]) do |file, acc|
    File.read(file).split(',').each_with_index do |cell, i|
      next if cell == '-'

      acc[i] = (acc[i] || 0) + cell.to_i
    end
  end
end

STEP_ENV_KEYS = %w[
  AC_XCODEPROJ_PATH AC_REPOSITORY_DIR AC_COCOAPODS_VERSION STUB_RBENV
  STUB_POD_FAIL_ON STUB_POD_EXIT STUB_GEM_FAIL_ON STUB_GEM_EXIT
  STUB_SUDO_FAIL_ON STUB_SUDO_EXIT
].freeze

# Run main.rb in a subprocess with the given ENV overrides, from `chdir`.
# Every step / stub key not given is explicitly UNSET in the child, so the
# parent's environment can never leak into a validation test.
def run_main(env = {}, chdir:, stub_bin:)
  child_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
  child_env['PATH'] = "#{stub_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}"
  child_env['AC_TEST_COVERAGE_DIR'] = COVERAGE_DIR
  Open3.capture3(child_env, 'ruby', "-r#{COVERAGE_HELPER}", MAIN_RB, chdir: chdir)
end

# Commands main.rb handed to runCommand, in order (from its @@[command] log).
def logged_commands(out)
  out.lines.grep(/\A@@\[command\] /).map { |l| l.sub('@@[command] ', '').chomp }
end

# Working directory a stub reported for the first call matching `pattern`.
def stub_cwd(out, pattern)
  line = out.lines.find { |l| l.include?(pattern) }
  line && line[/\[cwd=(.*)\]/, 1]
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading contract' do
  let(:tmpdir)   { Dir.mktmpdir('deintegrate_load_test') }
  let(:stub_bin) { build_stub_bin(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  it 'defines runCommand when required' do
    expect(defined?(runCommand)).to eq('method')
  end

  it 'does not run the step when required (even next to a Podfile)' do
    build_project(tmpdir, subdir: '')
    out, err, status = Open3.capture3(
      { 'PATH' => "#{stub_bin}#{File::PATH_SEPARATOR}#{ENV.fetch('PATH', '')}" },
      'ruby', '-e', "require #{MAIN_RB.dump}; puts 'loaded'",
      chdir: tmpdir
    )
    expect(status.exitstatus).to eq(0), err
    expect(out).to eq("loaded\n")
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#runCommand' do
  context 'happy path' do
    it 'returns nil when the command succeeds' do
      allow($stdout).to receive(:puts)
      expect(runCommand('true')).to be_nil
    end

    it 'echoes the command with the @@[command] prefix' do
      expect { runCommand('true') }.to output("@@[command] true\n").to_stdout
    end

    it 'passes the command string to system verbatim' do
      allow($stdout).to receive(:puts)
      expect(self).to receive(:system).with('pod _1.11.3_ deintegrate').and_return(true)
      runCommand('pod _1.11.3_ deintegrate')
    end

    it 'lets the child process write straight to stdout' do
      expect { runCommand('echo deintegrated') }
        .to output(/@@\[command\] echo deintegrated\ndeintegrated\n/).to_stdout_from_any_process
    end
  end

  context 'error branch' do
    before { allow($stdout).to receive(:puts) }

    it 'exits when the command returns a non-zero status' do
      expect { runCommand('false') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it 'propagates the exact exit status of the failed command' do
      expect { runCommand("sh -c 'exit 3'") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end

    it 'exits with 127 when the command cannot be found' do
      expect { runCommand('ac_no_such_command_xyz') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(127) }
    end

    it 'still logs the command before exiting' do
      allow($stdout).to receive(:puts).and_call_original
      expect do
        runCommand('false')
      rescue SystemExit
        nil
      end.to output("@@[command] false\n").to_stdout
    end
  end

  context 'empty / nil input' do
    before { allow($stdout).to receive(:puts) }

    it 'exits non-zero (127) for an empty command string' do
      expect { runCommand('') }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(127) }
    end

    it 'raises TypeError for a nil command' do
      expect { runCommand(nil) }.to raise_error(TypeError)
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'ENV validation' do
  let(:tmpdir)       { Dir.mktmpdir('deintegrate_env_test') }
  let(:stub_bin)     { build_stub_bin(tmpdir) }
  # Relative to AC_REPOSITORY_DIR, as Appcircle supplies it.
  let(:project_path) { 'app/MyApp.xcodeproj' }

  after { FileUtils.rm_rf(tmpdir) }

  def run_step(env = {})
    run_main(env, chdir: tmpdir, stub_bin: stub_bin)
  end

  describe 'AC_XCODEPROJ_PATH' do
    it 'missing: falls back to the working directory and skips when it has no Podfile' do
      out, _err, status = run_step
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Podfile does not exists.')
      expect(out).not_to include('STUB-')
    end

    it 'missing: deintegrates the working directory when it has a Podfile' do
      build_project(tmpdir, subdir: '')
      out, _err, status = run_step
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(tmpdir))
    end

    it 'empty: resolves to the repository root' do
      build_project(tmpdir, subdir: '')
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => '', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('Project extension must be xcodeproj.')
      expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(tmpdir))
    end

    it 'empty: skips when the repository root has no Podfile' do
      build_project(tmpdir) # Podfile only under app/
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => '', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Podfile does not exists.')
      expect(out).not_to include('STUB-pod')
    end

    it 'whitespace only: is treated as empty by the extension check' do
      build_project(tmpdir, subdir: '')
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => '   ', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).not_to include('Project extension must be xcodeproj.')
      expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
    end

    it 'valid .xcodeproj: deintegrates inside the project directory' do
      project_dir = build_project(tmpdir)
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => project_path, 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(project_dir))
    end

    it 'wrong extension: exits 0 with a message and never runs pod' do
      build_project(tmpdir, project: 'MyApp.xcworkspace')
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => 'app/MyApp.xcworkspace', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Project extension must be xcodeproj.')
      expect(out).not_to include('STUB-')
      expect(logged_commands(out)).to be_empty
    end

    it 'no extension: is rejected like a wrong extension' do
      build_project(tmpdir, project: 'MyApp')
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => 'app/MyApp', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Project extension must be xcodeproj.')
      expect(out).not_to include('STUB-')
    end

    it 'wrong extension and no Podfile: the Podfile check wins' do
      build_project(tmpdir, project: 'MyApp.xcworkspace', podfile: false)
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => 'app/MyApp.xcworkspace', 'AC_REPOSITORY_DIR' => tmpdir)
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Podfile does not exists.')
      expect(out).not_to include('Project extension must be xcodeproj.')
    end
  end

  describe 'AC_REPOSITORY_DIR' do
    it 'missing: uses the project path as-is' do
      project_dir = build_project(tmpdir)
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => File.join(project_dir, 'MyApp.xcodeproj'))
      expect(status.exitstatus).to eq(0)
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(project_dir))
    end

    it 'empty: resolves the project path relative to the working directory' do
      project_dir = build_project(tmpdir)
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => project_path, 'AC_REPOSITORY_DIR' => '')
      expect(status.exitstatus).to eq(0)
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(project_dir))
    end

    it 'set: is joined with a relative project path' do
      repo = File.join(tmpdir, 'repo')
      project_dir = build_project(repo)
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => project_path, 'AC_REPOSITORY_DIR' => repo)
      expect(status.exitstatus).to eq(0)
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(project_dir))
    end

    it 'set: an absolute project path takes precedence' do
      project_dir = build_project(tmpdir, subdir: 'elsewhere')
      out, _err, status = run_step(
        'AC_XCODEPROJ_PATH' => File.join(project_dir, 'MyApp.xcodeproj'),
        'AC_REPOSITORY_DIR' => File.join(tmpdir, 'repo')
      )
      expect(status.exitstatus).to eq(0)
      expect(stub_cwd(out, 'STUB-pod deintegrate')).to eq(File.realpath(project_dir))
    end

    it 'non-existent directory: exits 0 with the Podfile message' do
      out, _err, status = run_step('AC_XCODEPROJ_PATH' => project_path, 'AC_REPOSITORY_DIR' => File.join(tmpdir, 'nope'))
      expect(status.exitstatus).to eq(0)
      expect(out).to include('Podfile does not exists.')
      expect(out).not_to include('STUB-')
    end
  end

  describe 'AC_COCOAPODS_VERSION' do
    let(:base_env) { { 'AC_XCODEPROJ_PATH' => project_path, 'AC_REPOSITORY_DIR' => tmpdir } }

    context 'missing / empty, no Podfile.lock' do
      before { build_project(tmpdir) }

      it 'missing: uses the system pod without installing cocoapods' do
        out, _err, status = run_step(base_env)
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
        expect(out).not_to include('STUB-gem')
        expect(out).not_to include('STUB-sudo')
      end

      it 'empty: is treated as missing' do
        out, _err, status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => ''))
        expect(status.exitstatus).to eq(0)
        expect(out).not_to include('Cocoapods version =')
        expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      end
    end

    context 'missing, version taken from Podfile.lock' do
      it 'installs the locked version with sudo when rbenv is absent' do
        build_project(tmpdir, lock: podfile_lock('1.12.1'))
        out, _err, status = run_step(base_env)
        expect(status.exitstatus).to eq(0)
        expect(out).to include('Podfile.lock version = 1.12.1')
        expect(logged_commands(out)).to eq([
          'sudo gem install cocoapods -v 1.12.1 --no-document',
          'pod _1.12.1_ deintegrate'
        ])
        expect(out).to include('STUB-sudo gem install cocoapods -v 1.12.1 --no-document')
      end

      it 'installs the locked version without sudo when rbenv is present' do
        build_project(tmpdir, lock: podfile_lock('1.12.1'))
        out, _err, status = run_step(base_env.merge('STUB_RBENV' => '1'))
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out)).to eq([
          'gem install cocoapods -v 1.12.1 --no-document',
          'pod _1.12.1_ deintegrate'
        ])
        expect(out).not_to include('STUB-sudo')
      end

      it 'empty AC_COCOAPODS_VERSION also falls back to Podfile.lock' do
        build_project(tmpdir, lock: podfile_lock('1.10.2'))
        out, _err, status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => ''))
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out).last).to eq('pod _1.10.2_ deintegrate')
      end

      it 'uses the system pod when Podfile.lock has no COCOAPODS entry' do
        build_project(tmpdir, lock: "PODS:\n  - Alamofire (5.6.4)\n")
        out, _err, status = run_step(base_env)
        expect(status.exitstatus).to eq(0)
        expect(out).not_to include('Podfile.lock version =')
        expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      end

      it 'uses the system pod when Podfile.lock is empty' do
        build_project(tmpdir, lock: '')
        out, _err, status = run_step(base_env)
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out)).to eq(['pod --version', 'pod deintegrate'])
      end
    end

    context 'set' do
      it 'installs the pinned version with sudo when rbenv is absent' do
        build_project(tmpdir)
        out, _err, status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => '1.11.3'))
        expect(status.exitstatus).to eq(0)
        expect(out).to include('Cocoapods version = 1.11.3')
        expect(logged_commands(out)).to eq([
          'sudo gem install cocoapods -v 1.11.3 --no-document',
          'pod _1.11.3_ deintegrate'
        ])
      end

      it 'installs the pinned version without sudo when rbenv is present' do
        build_project(tmpdir)
        out, _err, status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => '1.11.3', 'STUB_RBENV' => '1'))
        expect(status.exitstatus).to eq(0)
        expect(logged_commands(out)).to eq([
          'gem install cocoapods -v 1.11.3 --no-document',
          'pod _1.11.3_ deintegrate'
        ])
      end

      it 'takes precedence over the Podfile.lock version' do
        build_project(tmpdir, lock: podfile_lock('1.12.1'))
        out, _err, status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => '1.11.3'))
        expect(status.exitstatus).to eq(0)
        expect(out).not_to include('Podfile.lock version =')
        expect(logged_commands(out).last).to eq('pod _1.11.3_ deintegrate')
      end

      it 'never runs pod --version' do
        build_project(tmpdir)
        out, _err, _status = run_step(base_env.merge('AC_COCOAPODS_VERSION' => '1.11.3'))
        expect(logged_commands(out)).not_to include('pod --version')
      end
    end
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'Command failures' do
  let(:tmpdir)   { Dir.mktmpdir('deintegrate_fail_test') }
  let(:stub_bin) { build_stub_bin(tmpdir) }
  let(:base_env) { { 'AC_XCODEPROJ_PATH' => 'app/MyApp.xcodeproj', 'AC_REPOSITORY_DIR' => tmpdir } }

  before { build_project(tmpdir) }
  after  { FileUtils.rm_rf(tmpdir) }

  def run_step(env)
    run_main(env, chdir: tmpdir, stub_bin: stub_bin)
  end

  it 'exits with the sudo gem install status and skips deintegrate' do
    out, _err, status = run_step(base_env.merge(
      'AC_COCOAPODS_VERSION' => '1.11.3', 'STUB_SUDO_FAIL_ON' => 'gem install', 'STUB_SUDO_EXIT' => '5'
    ))
    expect(status.exitstatus).to eq(5)
    expect(out).not_to include('STUB-pod')
  end

  it 'exits with the gem install status (rbenv) and skips deintegrate' do
    out, _err, status = run_step(base_env.merge(
      'AC_COCOAPODS_VERSION' => '1.11.3', 'STUB_RBENV' => '1',
      'STUB_GEM_FAIL_ON' => 'install', 'STUB_GEM_EXIT' => '6'
    ))
    expect(status.exitstatus).to eq(6)
    expect(out).not_to include('STUB-pod')
  end

  it 'exits with the pod --version status and skips deintegrate' do
    out, _err, status = run_step(base_env.merge('STUB_POD_FAIL_ON' => '--version', 'STUB_POD_EXIT' => '4'))
    expect(status.exitstatus).to eq(4)
    expect(out).not_to include('STUB-pod deintegrate')
  end

  it 'exits with the pod deintegrate status' do
    out, _err, status = run_step(base_env.merge('STUB_POD_FAIL_ON' => 'deintegrate', 'STUB_POD_EXIT' => '7'))
    expect(status.exitstatus).to eq(7)
    expect(out).to include('STUB-pod deintegrate')
  end

  it 'exits 127 when pod is not installed' do
    File.delete(File.join(stub_bin, 'pod'))
    env = base_env.merge('AC_COCOAPODS_VERSION' => '1.11.3', 'STUB_RBENV' => '1')
    # Keep only the stub dir and system dirs on PATH so a real pod cannot be found.
    child_env = STEP_ENV_KEYS.to_h { |k| [k, nil] }.merge(env)
    child_env['PATH'] = "#{stub_bin}#{File::PATH_SEPARATOR}/usr/bin#{File::PATH_SEPARATOR}/bin"
    child_env['AC_TEST_COVERAGE_DIR'] = COVERAGE_DIR
    _out, _err, status = Open3.capture3(child_env, RbConfig.ruby, "-r#{COVERAGE_HELPER}", MAIN_RB, chdir: tmpdir)
    expect(status.exitstatus).to eq(127)
  end
end
# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  # Fold in the counts collected from the `ruby main.rb` subprocesses so the
  # guarded top-level block is not reported as dead code.
  child     = subprocess_coverage
  data      = result[main_path].each_with_index.map do |count, idx|
    count.nil? ? nil : count + (child[idx] || 0)
  end
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "  \e[90mMerged from the in-process function tests and the `ruby main.rb`"
  puts "  ENV validation / failure subprocesses.\e[0m"
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  FileUtils.rm_rf(COVERAGE_DIR)
  exit exit_code
end
