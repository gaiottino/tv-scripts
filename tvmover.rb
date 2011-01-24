#!/usr/bin/env ruby

# Ruby TV File Mover
# Written by Brian Stolz - brian@tecnobrat.com

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
require File.expand_path(File.dirname(__FILE__)) + '/net-http-compression.rb'
require File.expand_path(File.dirname(__FILE__)) + '/overrides.rb'
include REXML

API_KEY = 'F63030FC56E9E594'

# OVERRIDES = {
#   'csi'                 => 'csi: crime scene investigation',
#   'csi new york'        => 'csi ny',
#   'human target 2010'   => 'human target',
#   'law order svu'       => 'law order special victims unit',
#   'shit my dad says'    => '$#*! my dad says',
#   'the office'          => 'the office us'
# }

def usage()
  puts
  puts "Moves your files into a directory."
  puts
  puts "Usage: ruby tvmover.rb <target-directory> [source directory]"
  puts
  exit
end

class Series

  attr_reader :episodes

  def initialize(name)
    @name = name
    puts "Doing lookup on #{@name}"
    do_name_overrides
    @episodes = Hash.new

    series_xml = get_series_xml()
    @series_xmldoc = Document.new(series_xml)
  end

  def name
    return nil if @series_xmldoc.elements["Series/SeriesName"].nil?
    @series_xmldoc.elements["Series/SeriesName"].text
  end

  def do_name_overrides
    @name = Overrides.override(@name)
    # puts "Original >>> #{@name}"
    # 
    # @name = @name.gsub(' and ', ' ')
    # override = OVERRIDES[@name.downcase]
    # @name = override unless override.nil?
    # 
    # puts "Searching >> #{@name}"
  end

  def id()
    @series_xmldoc.elements["Series/id"].text
  end

  def strip_dots(s)
    s.gsub(".","")
  end

  def get_series_xml
    url = URI.parse("http://thetvdb.com/api/GetSeries.php?seriesname=#{CGI::escape(@name)}&language=en").to_s


    puts "Getting: #{url}"

    res = RemoteRequest.new("get").read(url)

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
end

def move_files!(filename, destination_path, episode)
  move_file!(filename, destination_path, episode[0], episode[1])
end

def move_file!(filename, destination_path, show, season)
  if show.nil? or season.nil?
    puts "Error getting show data for #{filename}"
    return filename
  end

  show = sanitize_name(show)
  new_dir = destination_path + Pathname(show) + Pathname("Season #{season}")
  new_filename = new_dir + filename.basename

  #Filename has not changed
  if new_filename == filename
    return filename
  end

  if new_filename.file?
    puts "Can not rename #{filename} to #{new_filename} detected a duplicate"
    return filename
  else
    puts "Before: #{filename}"
    puts "Show: #{show}"
    puts "Season: #{season}"
    puts "After:  #{new_filename}"
    puts
    FileUtils.mkdir_p(new_dir)
    File.rename(filename, new_filename) unless filename == new_filename
  end

  filename = new_filename
  return filename
end

def get_details(file)
  # figure out what the show is based on path and filename
  season = nil
  show_name = nil

  return nil unless  /\d+/ =~ file.basename

  puts file.basename

  # check for a match in the style of 1x01
  if /^(.*)[ |\.](\d+)[x|X](\d+)([x|X](\d+))?/ =~ file.basename
    unless $4.nil?
      episode_number2 = $5.to_s
    end
    show_name, season, episode_number = $1.to_s, $2.to_s, $3.to_s
  # check for s01e01
  elsif /^(.*)[ |\.][s|S](\d+)[e|E](\d+)([e|E](\d+))?/ =~ file.basename
    unless $5.nil?
      episode_number2 = $5.to_s
    end
    show_name, season, episode_number = $1.to_s, $2.to_s, $3.to_s
  # check for 101
  elsif /^(.*)\.(\d{1})(\d{2})\./ =~ file.basename
    show_name, season, episode_number = $1.to_s, $2.to_s, $3.to_s
  # the simple case
  elsif /^(.*)[ |\.]\d+/ =~ file.basename
    show_name = $1.to_s
    episode_number = /\d+/.match(file.basename)[0]
    if episode_number.to_i > 99 && episode_number.to_i < 1900
      # handle the format 308 (season, episode) with special exclusion to year names Eg. 2000 1995
      season = episode_number[0,episode_number.length-2]
      episode_number = episode_number[episode_number.length-2 , episode_number.length]
    end
  end

  return nil if show_name.nil?
  season = season.to_i.to_s
  series = Series.new show_name.gsub(/\./, " ")
  return nil if series.name.nil?
  show_name = series.name

  puts "Show: #{show_name}"
  puts "Season: #{season}"
  puts "Episode: #{episode_number}"
  puts "Episode2: #{episode_number2}" if episode_number2

  return nil if episode_number.to_i > 99
  [show_name, season]
end

def sanitize_name(name)
  name.gsub!(/\:/, "-")
  ["?","\\",":","\"","|",">", "<", "*", "/"].each {|l| name.gsub!(l,"")}
  name.strip
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
      def self.read(url)
        attempt_number=0
        errors=""
        begin
          attempt_number=attempt_number+1
          if (attempt_number > 10) then
            return nil
          end

          file = Net::HTTP.get_response URI.parse(url)
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
          sleep 10
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

parser = GetoptLong.new
parser.set_options(
  ["-h", "--help", GetoptLong::NO_ARGUMENT]
)

loop do
  opt, arg = parser.get
  break if not opt
  case opt
    when "-h"
      usage
      break
  end
end

destination_path = ARGV.shift
source_path = ARGV.shift

if not source_path
  source_path = Pathname.new(Dir.getwd)
else
  source_path = Pathname.new(source_path)
end

if not destination_path
  puts "Error, need destination path"
  usage
  exit
else
  destination_path = Pathname.new(destination_path)
end

if not source_path.directory?
  puts "Directory not found " + source_path
  usage
  exit
end

if not destination_path.directory?
  puts "Directory not found " + destination_path
  usage
  exit
end

puts "Starting to scan files" unless ENV['QUIET'] = "true"
Find.find(source_path.to_s) do |filename|
  Find.prune if [".","..",".ruby-tvmover"].include? filename
  if filename =~ /\.(avi|mpg|mpeg|mp4|divx|mkv)$/
    episode = get_details(Pathname.new(filename))
    if episode
      begin
        move_files!(Pathname.new(filename), destination_path,episode)
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
      puts
      puts "##########"
      puts "#  ERROR #"
      puts "##########"
      puts "No data found for #{filename}"
      puts "##########"
      puts
    end
  end
end

puts "Done!" unless ENV['QUIET'] = "true"

