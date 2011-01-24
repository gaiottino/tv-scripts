#!/usr/bin/env ruby

# Ruby TV File Renamer
# Written by Brian Stolz - brian@tecnobrat.com
# Originally written by Sam Saffron - sam.saffron@gmail.com

###################
# READ THE README #
###################

require 'yaml'
require 'getoptlong'
require 'net/http'
require "cgi"
require 'rexml/document'
require 'pathname'
require 'find'
require 'fileutils'
require 'pp'
require 'time'
include REXML
require File.expand_path(File.dirname(__FILE__)) + '/net-http-compression.rb'
require File.expand_path(File.dirname(__FILE__)) + '/overrides.rb'

API_KEY = 'F63030FC56E9E594'

# How long to cache files.  Set to 16 days so that it doesn't redownload
# if a series skips a week, and 2 extra days incase of a slow release.
# It will automatically redownload if its a brand new file (new episodes).
@@time_to_live = 60*60*24*16

@@series_cache = 24*60*60 # Should be long enough for one run of the script

def usage()
  puts
  puts "Renames your files."
  puts
  puts "Usage: ruby tvrenamer.rb <source-directory> [--refresh|-r] [--format=<format>|-f <format>]"
  puts
  puts "\t--nocache          Do not cache old renames at all"
  puts "\t--refresh          Refresh cache of downloaded XML"
  puts "\t--format=<format>  Format to output the filenames"
  puts
  exit
end

class Series

  attr_reader :name, :episodes

  def initialize(name, refresh)
    @name = name
    do_name_overrides
    @series_xml_path = Pathname.new("#{@@config_dir}/xml_cache/series_data/" + @name + ".xml")
    @episodes_xml_path = Pathname.new("#{@@config_dir}/xml_cache/episode_data/" + @name + ".xml")
    @episodes = Hash.new
    @series_xml_path.delete if @series_xml_path.file?
    @episodes_xml_path.delete if @episodes_xml_path.file?
    if not @series_xml_path.file?
      series_xml = get_series_xml()
      #ensure we have a xml_cache dir
      unless @series_xml_path.dirname.directory?
        FileUtils.mkdir_p(@series_xml_path.dirname.to_s)
      end
      @series_xml_path.open("w")  {|file| file.puts series_xml} unless series_xml.nil? or series_xml.empty?
      @series_xmldoc = Document.new(series_xml)
    else
      @series_xml_path.open("r") {|file| @series_xmldoc = Document.new(file) }
    end

    return nil if series_xml.nil? or series_xml.empty?

    @name = @series_xmldoc.elements["Series/SeriesName"].text

    if not @episodes_xml_path.file?
      episodes_xml = get_episodes_xml(id)

      #ensure we have a xml_cache dir
      unless @episodes_xml_path.dirname.directory?
        FileUtils.mkdir_p(@episodes_xml_path.dirname.to_s)
      end
      @episodes_xml_path.open("w")  {|file| file.puts episodes_xml}
      @episodes_xmldoc = Document.new(episodes_xml) unless episodes_xml.nil?
    else
      @episodes_xml_path.open("r") {|file| @episodes_xmldoc = Document.new(file) }
    end

    @episodes_xmldoc.elements.each("Data/Episode") do |episode|
      @episodes[episode.elements["SeasonNumber"].text] = Hash.new unless @episodes[episode.elements["SeasonNumber"].text].class == Hash
      @episodes[episode.elements["SeasonNumber"].text][episode.elements["EpisodeNumber"].text] = episode.elements["EpisodeName"].text
    end unless @episodes_xmldoc.nil?
  end

  def id()
    @series_xmldoc.elements["Series/id"].text
  end

  def do_name_overrides
    if @name == "CSI" or @name == "CSI: Las Vegas"
      @name = "CSI: Crime Scene Investigation"
    end
    
    @name = Overrides.override(@name)
  end

  def strip_dots(s)
    s.gsub(".","")
  end
  def get_episodes_xml(series_id)
    uri = URI.parse("http://thetvdb.com/api/#{API_KEY}/series/#{series_id}/all/en.xml")
    res = RemoteRequest.new("get").read(uri)

    if res.nil?
      puts "Could not download XML Data for series ID #{series_id} -- #{url}"
      return nil
    end

    doc = Document.new res
    doc.elements.each("Data") do |element|
      return element.to_s
    end
  end

  def get_series_xml
    name = @name.sub(/\(/, "").sub(/\)/, "")
    uri = URI.parse("http://thetvdb.com/api/GetSeries.php?seriesname=#{CGI::escape(name)}&language=en")
    puts uri.to_s

    res = RemoteRequest.new("get").read(uri)

    doc = Document.new res

    series_xml = nil
    series_element = nil

    doc.elements.each("Data/Series") do |element|
      series_element ||= element
        if strip_dots(element.elements["SeriesName"].text.downcase) == strip_dots(@name.downcase)
        series_element = element
        break
      end
    end
    series_xml = series_element.to_s
    series_xml
  end

  def get_episode(filename, season, episode_number, refresh)
    Episode.new(self, filename, season, episode_number, refresh)
  end
end

class Episode
  attr_reader :series, :season, :filename, :episode_number, :raw_name
  def initialize(series, filename, season, episode_number, refresh)
    @filename = filename
    @series = series
    @season = season
    @episode_number = episode_number
    @raw_name = series.episodes[season][episode_number]
  end

  def name()
    get_name_and_part[0]
  end

  def part()
    get_name_and_part[1]
  end

  def get_name_and_part
    name = raw_name
    if name =~ /^(.*) \(([0-9]*)\)$/
      name = $1
      part = $2
    else
      part = nil
    end
    return [name, part]
  end
end

def fix_names!(epis)
  episodes = {}
  epis.each do |epi|
    episode = {
      epi.episode_number => {
        'name' => epi.name,
        'part' => epi.part,
        'series' => epi.series.name,
        'season' => epi.season,
        'episode_number' => epi.episode_number
      }
    }
    episodes.merge! episode
  end

  fix_name!(episodes.sort, epis.first.filename)
end

def fix_name!(episode, filename)
  return nil if episode.nil?
  rename_dir = false

  format_values = {
    '%S' => episode[0][1]['series'],
    '%s' => episode[0][1]['season'].rjust(2, "0"),
    '%E1' => episode[0][1]['name'],
    '%e1' => episode[0][1]['episode_number'].rjust(2, "0"),
    '%p1' => episode[0][1]['part'],
    '%E2' => episode[1].nil? ? nil : episode[1][1]['name'],
    '%e2' => episode[1].nil? ? nil : episode[1][1]['episode_number'].rjust(2, "0"),
    '%p2' => episode[1].nil? ? nil : episode[1][1]['part']
  }

  new_basename = make_name(format_values, String.new(@@config['format']))

  parent_dir = filename.dirname.parent
  show_dir = parent_dir.basename
  new_show_dir = sanitize_name(episode[0][1]['series'])

  if new_show_dir != show_dir.to_s
    old_dir = parent_dir
    new_dir = parent_dir.parent + Pathname(new_show_dir)
    rename_dir = true
  end

  new_filename = filename.dirname + (new_basename + filename.extname)

  if new_filename.to_s =~ /\%/
    puts "ERROR: FILENAME NOT COMPLETE"
    puts filename
    puts new_filename
    exit
  end

  if rename_dir
    puts "Renaming directory #{old_dir} to #{new_dir}"
    File.rename(old_dir, new_dir) unless old_dir == new_dir
    puts "I had to rename a directory!  Restarting scan...."
    return "restart"
  end

  #Filename has not changed
  if new_filename.to_s == filename.to_s
    @@renamer_cache.merge!({new_filename => Time.now})
    Pathname.new("#{@@config_dir}/renamer_cache.txt").open("a")  {|file| file.puts "#{Time.now.to_s}|||||#{new_filename}"}
    return filename
  end

  if new_filename.file?
    puts "Can not rename #{filename} to #{new_filename} detected a duplicate"
  else
    puts "Before: #{filename}"
    puts "After: #{new_filename}"
    File.rename(filename, new_filename) unless filename == new_filename
    puts
    @@renamer_cache.merge!({new_filename => Time.now})
    Pathname.new("#{@@config_dir}/renamer_cache.txt").open("a")  {|file| file.puts "#{Time.now.to_s}|||||#{new_filename}"}
  end

  filename = new_filename
end

def make_name(format_values, format_string)
  new_basename = String.new(format_string)
  format_values.each do |key,value|
    unless value.nil?
      new_basename.gsub!(Regexp.new(key), value)
    end
  end

  until new_basename.gsub!(/\[[^\[]*%[^\[\]]*\]/, "").nil?; end

  new_basename.gsub!(/\]/, "")
  new_basename.gsub!(/\[/, "")

  # sanitize the name
  new_basename.gsub!(/\:/, "-")
  ["?","\\",":","\"","|",">", "<", "*", "/"].each {|l| new_basename.gsub!(l,"")}
  new_basename.strip
end

def sanitize_name(name)
  # sanitize the name
  name.gsub!(/\:/, "-")
  ["?","\\",":","\"","|",">", "<", "*", "/"].each {|l| name.gsub!(l,"")}
  name.strip
end

def drop_extension(filename)
  Pathname.new(filename.to_s[0, filename.to_s.length - filename.extname.length])
end

def get_details(file, refresh)

  # figure out what the show is based on path and filename
  season = nil
  show_name = nil

  file.parent.ascend do |item|
    if not season
      season = /\d+/.match(item.basename.to_s)
      if season
        #possibly we may want special handling for 24
        season = season[0]
      else
        season = "1"
        show_name = item.basename.to_s
        break
      end
    else
      show_name = item.basename.to_s
      break
    end
  end

  return nil unless  /\d+/ =~ file.basename

  # check for a match in the style of 1x01
  if /(\d+)[x|X](\d+)([x|X](\d+))?/ =~ file.basename
    unless $4.nil?
      episode_number2 = $4.to_s
    end
    season, episode_number = $1.to_s, $2.to_s
  # check for s01e01
  elsif /[s|S](\d+)x?[e|E](\d+)([e|E](\d+))?/ =~ file.basename
    unless $4.nil?
      episode_number2 = $4.to_s
    end
    season, episode_number = $1.to_s, $2.to_s
  # check for 101
  elsif /^(.*)\.(\d{1})(\d{2})\./ =~ file.basename
    show_name, season, episode_number = $1.to_s, $2.to_s, $3.to_s
  # the simple case
  else
    episode_number = /\d+/.match(file.basename)[0]
    if episode_number.to_i > 99 && episode_number.to_i < 1900
      # handle the format 308 (season, episode) with special exclusion to year names Eg. 2000 1995
      season = episode_number[0,episode_number.length-2]
      episode_number = episode_number[episode_number.length-2 , episode_number.length]
    end
  end

  season = season.to_i.to_s
  episode_number = episode_number.to_i.to_s
  episode_number2 = episode_number2.to_i.to_s unless episode_number2.nil?

  return nil if episode_number.to_i > 99

  if @@series[show_name].nil?
    @@series[show_name] = Series.new show_name, refresh
    series = @@series[show_name]
  else
    series = @@series[show_name]
  end
  return nil if series.episodes.size < 1

  begin
    if episode_number2.nil?
      [series.get_episode(file, season, episode_number, refresh)]
    else
      [series.get_episode(file, season, episode_number, refresh), series.get_episode(file, season, episode_number2, refresh)]
    end
  rescue => err
    puts
    puts "Error: #{err}"
    puts
    err.backtrace.each do |line|
      puts line
    end
    puts
  end
end


class RemoteRequest
  def initialize(method)
    method = 'get' if method.nil?
    @opener = self.class.const_get(method.capitalize)
  end

  def read(url)
    data = @opener.read(url)
    data
  end

  private
    class Get
      def self.read(uri)
        attempt_number=0
        errors=""
        begin
          attempt_number=attempt_number+1
          if (attempt_number > 2) then
            return nil
          end

          file = Net::HTTP.get_response uri
          if (file.message != "OK") then
            raise InvalidResponseFromFeed, file.message
          end
        rescue Timeout::Error => err
          puts "Timeout Error: #{err}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 10
          retry
        rescue Errno::ECONNREFUSED => err
          puts "Connection Error: #{err}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 10
          retry
        rescue SocketError => exception
          puts "Socket Error: #{exception}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 10
          retry
        rescue EOFError => exception
          puts "Socket Error: #{exception}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 10
          retry
        rescue InvalidResponseFromFeed => err
          puts "Invalid response: #{err}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 1
          retry
        rescue => err
          puts "Invalid response: #{err}, sleeping for 10 secs, and trying again (Attempt #{attempt_number})."
          sleep 10
          retry
        else
          return file.plain_body
        end
      end
    end
end

class InvalidResponseFromFeed < RuntimeError
  def initialize(info)
  @info = info
  end
end

# Main program

format = nil
refresh = false
nocache = false

parser = GetoptLong.new
parser.set_options(
  ["-h", "--help", GetoptLong::NO_ARGUMENT],
  ["-n", "--nocache", GetoptLong::NO_ARGUMENT],
  ["-r", "--refresh", GetoptLong::NO_ARGUMENT],
  ["-f", "--format", GetoptLong::OPTIONAL_ARGUMENT]
)

@@config = {}
@@series = {}

if !ENV["HOME"].nil?
  @@config_dir = "#{ENV["HOME"]}/.ruby-tvscripts"
elsif !ENV["APPDATA"].nil?
  @@config_dir = "#{ENV["APPDATA"]}/.ruby-tvscripts"
else
  @@config_dir = ""
end


if File.exist?("#{@@config_dir}/tvrenamer.yml")
  @@config = YAML.load_file( "#{@@config_dir}/tvrenamer.yml" )
end

loop do
  opt, arg = parser.get
  break if not opt
  case opt
    when "-h"
      usage
      break
    when "-f"
      format = arg
      break
    when "-r"
      refresh = true
      break
    when "-n"
      nocache = true
      break
  end
end

# If the format is overridden, use it.
unless format.nil?
  @@config['format'] = format
end

# If I have no format anywhere, use the default.
if @@config['format'].nil?
  @@config['format'] = "%S s%se%e1[e%e2] - %E1[ (Part %p1)][ - %E2[ (Part %p2)]]"
end

path = ARGV.shift

if not path
  path = Pathname.new(Dir.getwd)
else
  path = Pathname.new(path)
end

if not path.directory?
  puts "Directory not found " + path
  usage
  exit
end

@@renamer_cache = {}

cache_file = Pathname.new("#{@@config_dir}/renamer_cache.txt")

puts "Loading cache" unless ENV['QUIET'] = "true"
cache_file.readlines.each { |line|
    arr = line.chomp.split("|||||")
    @@renamer_cache.merge!({arr[1] => Time.parse(arr[0])})
} if cache_file.file?
puts "Loaded cache" unless ENV['QUIET'] = "true"

puts "Starting to scan files" unless ENV['QUIET'] = "true"
Dir.glob("**/*.{avi,mpg,mpeg,mp4,divx,mkv}") do |filename|
  filename = filename.to_s
  if nocache or @@renamer_cache[filename].nil? or @@renamer_cache[filename] < (Time.now - @@time_to_live)
    @@renamer_cache.delete(filename)
    episode = get_details(Pathname.new(filename), refresh)
    if episode
      begin
        if fix_names!(episode) == "restart"
          retry
        end
      rescue => err
        puts
        puts "Error: #{err}"
        puts
        err.backtrace.each do |line|
          puts line
        end
        puts
      end
    else
      puts "no data found for #{filename}"
    end
  end
end

Pathname.new("#{@@config_dir}/renamer_cache.txt").delete if Pathname.new("#{@@config_dir}/renamer_cache.txt").file?
@@renamer_cache.each do |filename,time|
  Pathname.new("#{@@config_dir}/renamer_cache.txt").open("a")  {|file| file.puts "#{time}|||||#{filename.to_s}"}
end
puts "Done!" unless ENV['QUIET'] = "true"

