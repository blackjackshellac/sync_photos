#!/usr/bin/env ruby
#
#

require 'optparse'
require 'logger'
require 'find'
require 'fileutils'
require 'readline'
require 'json'
require 'exifr'

ME=File.basename($0, ".rb")
MD=File.dirname(File.expand_path($0))

USER=ENV['USER']||ENV['LOGNAME']||"unknown"
TMP="/var/tmp/#{ME}/#{USER}"
DST="#{TMP}/backup"
LOG="#{TMP}/#{ME}.log"
CFG=File.join(MD, ME+".json")

class Logger
	def die(msg)
		$stdout = STDOUT
		self.error(msg)
		exit 1
	end

	def puts(msg)
		self.info(msg)
	end

	def write(msg)
		self.info(msg)
	end
end

def set_logger(stream, level=Logger::INFO)
	log = Logger.new(stream)
	log.level = level
	log.datetime_format = "%Y-%m-%d %H:%M:%S"
	log.formatter = proc do |severity, datetime, progname, msg|
		"#{severity} #{datetime}: #{msg}\n"
	end
	log
end

$log=set_logger(STDERR)

$opts = {
	:uid=>%x/id -u/.strip,
	:src => "/run/media/#{USER}",
	:dst => ENV["SYNC_PHOTOS"]||DST,
	:dirs => [],
	:dryrun => false,
	:verbose => false,
	:quiet => false,
	:progress => false,
	:purge => false,
	:yes => false,
	:log => nil
}

def readConfig
	begin
		return File.read(CFG)
	rescue => e
		$log.error "reading json config: #{CFG} [#{e.message}]"
		return nil
	end
end

def parseConfig(json)
	return { :configs =>{} } if json.nil?
	begin
		return JSON.parse(json, :symbolize_names=>true)
	rescue => e
		$log.die "Failed to parse json config: #{CFG} [#{e.message}]"
	end
end

def vputs(msg, force=false)
	$stdout.puts msg if force || $opts[:verbose]
end

def getSymbol(string)
	string=string[1..-1] if string[0].eql?(":")
	string.to_sym
end

RUN_OPTS={:trim=>false,:fail=>true,:verbose=>false,:quiet=>false}
def run_cmd(cmd, err_msg=nil, opts=RUN_OPTS)
	opts=RUN_OPTS.merge(opts)
	err_msg="Command failed to run: #{cmd}" if err_msg.nil?
	puts "$ "+cmd unless opts[:quiet]
	out=%x/#{cmd}/
	if $?.exitstatus != 0
		$log.die err_msg if opts[:fail]
		return nil
	end
	return opts[:trim] ? out.strip! : out
end

def get_dirs(src)
	dirs=[]
	FileUtils.chdir(src) {
		Dir.glob('*') { |dir|
			next unless File.directory?(dir)
			dirs << dir
		}
	}
	dirs
end

def parseOpts(gopts, jcfg)
	begin
		config_names=jcfg[:configs].keys
		optparser = OptionParser.new { |opts|
			opts.banner = "#{ME}.rb [options]\n"

			opts.on('-c', '--config NAME', String, "Config name, one of [#{config_names.join(',')}]") { |name|
				name=name.to_sym
				config=jcfg[:configs][name]
				$log.die "Unknown config name #{name}" if config.nil?
				$log.info "Setting config values for #{name}"
				config.keys.each { |key|
					$log.die "Unknown config value #{key}" unless gopts.key?(key)
					$log.info "gopts[#{key}]=#{config[key]}"
					gopts[key]=config[key]
				}
			}

			opts.on('-s', '--src DIR', String, "Source directory, default #{gopts[:src]}") { |src|
				gopts[:src]=src
			}

			opts.on('-d', '--dst DIR', String, "Backup directory, default #{gopts[:dst]}") { |dst|
				gopts[:dst]=dst
			}

			opts.on('-y', '--yes', "Answer yes to prompts") {
				gopts[:yes]=true
			}

			opts.on('-n', '--dry-run', "Dry run") {
				gopts[:dryrun]=true
			}

			opts.on('-p', '--progress', "Progress output") {
				gopts[:progress]=true
			}

			opts.on('--[no-]purge', "Delete after copy, default is #{gopts[:purge]}") { |p|
				gopts[:purge]=p
			}

			#opts.on('-L', '--log [FILE]', String, "Log to file instead of stdout, default #{gopts[:log]}") { |file|
			#	gopts[:log]=file||LOG
			#	$log.info "Logging to #{gopts[:log].inspect}"
			#}

			opts.on('-q', '--quiet', "Quiet things down") {
				gopts[:quiet]=true
				gopts[:verbose]=false
			}

			opts.on('-v', '--verbose', "Verbose output") {
				gopts[:verbose]=true
				gopts[:quiet]=false
			}

			opts.on('-D', '--debug', "Turn on debugging output") {
				$log.level = Logger::DEBUG
			}

			opts.on('-h', '--help', "Help") {
				$stdout.puts ""
				$stdout.puts opts
				$stdout.puts <<HELP

Description:

\tSync photos from source to destination directories sorting by YYYY/MM/DD
\tdates are grokked from EXIF data.  Uses rsync to transfer files from source
\tto destination directories.

Environment variables:

\tSYNC_PHOTOS  - destination directory for photo sync (#{ENV['SYNC_PHOTOS']||"not set"})

HELP
				exit 0
			}
		}
		optparser.parse!

		$log.die "Source directory not set" if gopts[:src].nil?

		FileUtils.mkdir_p(gopts[:dst])

		unless gopts[:log].nil?
			$log.debug "Logging file #{gopts[:log]}"
			FileUtils.mkdir_p(File.dirname(gopts[:log]))
			# open log to $stdout
			$stdout=File.open(gopts[:log], "a")
			# create a logger pointing to stdout
			$log=set_logger($stdout, $log.level)
			$stdout=$log
		end

	rescue OptionParser::InvalidOption => e
		$log.die e.message
	rescue => e
		$log.die e.message
	end

	gopts
end

$cfg = parseConfig(readConfig())
$opts=parseOpts($opts, $cfg)

def mkdir(basedir, subdir=nil)
	dir=subdir.nil? || subdir.empty? ? basedir : File.join(basedir, subdir)
	begin
		unless File.directory?(dir)
			vputs "Creating #{dir}"
			FileUtils.mkdir_p(dir)
		end
	rescue => e
		$log.error "Failed to create dir #{dir}: #{e.message}"
		dir=nil
	end
	return dir
end

#SYNC_PHOTO_FILES=.jpg,.jpeg,.png
SYNC_PHOTO_FILES=/(.*?)\.(jpg|jpeg|png)$/i
def sync(sdir, ddir, record=nil)
	skip = false
	total=0
	files=0
	dirs=0
	tstart=Time.new.to_i
	FileUtils.chdir(sdir) {
		vputs "Source dir = #{sdir}"
		vputs "  Dest dir = #{ddir}"
		Find.find(".") { |e|
			# strip off ./
			e=e[2..-1]
			next if e.nil?
			next if e[SYNC_PHOTO_FILES].nil?
			exif=EXIFR::JPEG.new(e)
			model=exif.model.nil? ? "unknown camera model" : exif.model
			model.strip!
			model.gsub!(/\s+/, "_")
			model.downcase!
			date_time=exif.date_time
			if date_time.nil?
				$log.warn "No exif date/time data, using now"
				date_time=Time.new
			end
			subdir=date_time.strftime("#{model}/%Y/%m/%d")
			path=mkdir(ddir, subdir)
			d=File.dirname(e)
			f=File.basename(e)
			FileUtils.chdir(d) {
				rsync_opts="-a"
				rsync_opts+="v" if $opts[:verbose]
				rsync_opts+=" --dry-run" if $opts[:dryrun]
				out=run_cmd("rsync #{rsync_opts} #{f} #{path}/#{f.downcase}", nil, :verbose=>$opts[:verbose], :quiet=>$opts[:quiet])
				puts out if $opts[:verbose] && !out.nil?
			}
			FileUtils.rm_f(e, :verbose=>$opts[:verbose]) if $opts[:purge]
		}
	}
end

begin
	sync($opts[:src], $opts[:dst])
rescue => e
	$log.die "sync failed: #{e.message}"
end

