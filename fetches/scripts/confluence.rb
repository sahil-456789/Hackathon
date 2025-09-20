#!/usr/bin/env ruby
# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'time'

# Load environment variables from .env file if it exists
begin
  require 'dotenv'
  Dotenv.load
rescue LoadError
  # dotenv gem not installed, skip loading .env file
end

# Constants - Replace these with your actual values
CONFLUENCE_BASE_URL = 'https://browserstack.atlassian.net' # Replace with your Confluence instance URL
API_TOKEN = ENV['CONFLUENCE_API_TOKEN'] || ENV['JIRA_API_TOKEN'] || 'your-api-token-here' # Set in environment or replace
EMAIL = ENV['CONFLUENCE_EMAIL'] || ENV['JIRA_EMAIL'] || 'your-email@company.com' # Set in environment or replace
OUTPUT_FILE = 'confluence_documents_data.txt'

# Document IDs will be collected from user input at runtime
DOCUMENT_IDS = [].freeze

class ConfluenceDocsFetcher
  def initialize
    @credentials = Base64.strict_encode64("#{EMAIL}:#{API_TOKEN}")
    @document_ids = []
  end

  def collect_document_ids_from_args
    # Check if document IDs were provided as command line arguments
    if ARGV.length > 0
      input = ARGV.join(' ')
      puts "📋 Using document IDs from command line: #{input}"
      
      # Parse input - handle commas, spaces
      ids = []
      
      if input.include?(',')
        # Comma-separated
        ids = input.split(',').map(&:strip)
      else
        # Space-separated (from ARGV)
        ids = ARGV.map(&:strip)
      end
      
      # Clean and validate IDs
      @document_ids = ids.map(&:strip)
                        .reject(&:empty?)
                        .select { |id| id.match?(/^\d+$/) }
                        .uniq
      
      invalid_ids = ids - @document_ids
      unless invalid_ids.empty?
        puts "⚠️  Skipped invalid document IDs: #{invalid_ids.join(', ')}"
      end
      
      if @document_ids.empty?
        puts '❌ No valid document IDs found in command line arguments!'
        puts 'Document IDs should be numeric (e.g., 123456789)'
        return false
      end
      
      puts "✅ Collected #{@document_ids.length} valid document IDs:"
      @document_ids.each_with_index { |id, index| puts "   #{index + 1}. #{id}" }
      puts
      
      return true
    end
    
    false
  end

  def collect_document_ids_interactive
    puts '📋 Enter Confluence Document IDs'
    puts 'You can enter document IDs in the following ways:'
    puts '1. Single ID: 123456789'
    puts '2. Multiple IDs separated by commas: 123456789,987654321,456789123'
    puts '3. Multiple IDs separated by spaces: 123456789 987654321 456789123'
    puts '4. One ID per line (press Enter twice when done)'
    puts
    puts 'How to find document IDs:'
    puts '- From URL: https://yourcompany.atlassian.net/wiki/spaces/DOCS/pages/123456789/Page+Title'
    puts '- The number after /pages/ is the document ID (123456789 in this example)'
    puts
    print 'Enter document IDs: '
    
    input = STDIN.gets.chomp.strip
    
    if input.empty?
      puts '❌ No document IDs provided!'
      return false
    end
    
    # Parse input - handle commas, spaces, or newlines
    ids = []
    
    if input.include?(',')
      # Comma-separated
      ids = input.split(',').map(&:strip)
    elsif input.include?(' ')
      # Space-separated
      ids = input.split(' ').map(&:strip)
    else
      # Single ID or newline-separated (collect multiple lines)
      ids = [input]
      
      # If it looks like they want to enter multiple IDs line by line
      if input.match?(/^\d+$/) && input.length > 5
        puts 'Enter additional document IDs (one per line, press Enter on empty line to finish):'
        loop do
          additional_input = STDIN.gets.chomp.strip
          break if additional_input.empty?
          ids << additional_input
        end
      end
    end
    
    # Clean and validate IDs
    @document_ids = ids.map(&:strip)
                      .reject(&:empty?)
                      .select { |id| id.match?(/^\d+$/) }
                      .uniq
    
    invalid_ids = ids - @document_ids
    unless invalid_ids.empty?
      puts "⚠️  Skipped invalid document IDs: #{invalid_ids.join(', ')}"
    end
    
    if @document_ids.empty?
      puts '❌ No valid document IDs found!'
      puts 'Document IDs should be numeric (e.g., 123456789)'
      return false
    end
    
    puts "✅ Collected #{@document_ids.length} valid document IDs:"
    @document_ids.each_with_index { |id, index| puts "   #{index + 1}. #{id}" }
    puts
    
    true
  end

  def collect_document_ids
    # Try command line arguments first, then interactive input
    return true if collect_document_ids_from_args
    collect_document_ids_interactive
  end

  def create_auth_headers
    {
      'Authorization' => "Basic #{@credentials}",
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
  end

  def make_request(url, params = {})
    uri = URI(url)
    uri.query = URI.encode_www_form(params) unless params.empty?
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Get.new(uri)
    create_auth_headers.each { |key, value| request[key] = value }
    
    response = http.request(request)
    
    case response.code
    when '200'
      JSON.parse(response.body)
    when '404'
      puts "Document not found (404) for URL: #{url}"
      nil
    when '403'
      puts "Access denied (403) for URL: #{url}"
      nil
    else
      puts "Error: HTTP #{response.code} - #{response.message} for URL: #{url}"
      puts "Response body: #{response.body}" if response.body
      nil
    end
  rescue StandardError => e
    puts "Request failed for #{url}: #{e.message}"
    nil
  end

  def fetch_document_by_id(doc_id)
    puts "Fetching document ID: #{doc_id}"
    content_url = "#{CONFLUENCE_BASE_URL}/wiki/rest/api/content/#{doc_id}"
    params = {
      'expand' => 'body.storage,version,space,ancestors,children.page'
    }
    
    document = make_request(content_url, params)
    
    if document
      puts "✅ Successfully fetched: #{document['title'] || 'Untitled'}"
    else
      puts "❌ Failed to fetch document ID: #{doc_id}"
    end
    
    document
  rescue StandardError => e
    puts "Error fetching document #{doc_id}: #{e.message}"
    nil
  end

  def fetch_all_documents
    puts "Fetching #{@document_ids.length} documents..."
    puts "Document IDs: #{@document_ids.join(', ')}"
    puts '=' * 80
    
    documents = []
    successful_fetches = 0
    failed_fetches = 0
    
    @document_ids.each_with_index do |doc_id, index|
      puts "\n[#{index + 1}/#{@document_ids.length}] Processing document ID: #{doc_id}"
      
      document = fetch_document_by_id(doc_id)
      
      if document
        documents << document
        successful_fetches += 1
      else
        failed_fetches += 1
      end
      
      # Add a small delay to be respectful to the API
      sleep(0.5) if index < @document_ids.length - 1
    end
    
    puts "\n" + '=' * 80
    puts "Fetch Summary:"
    puts "✅ Successful: #{successful_fetches}"
    puts "❌ Failed: #{failed_fetches}"
    puts "📄 Total documents retrieved: #{documents.length}"
    
    documents
  end

  def clean_html_content(html_content)
    return 'No content' if html_content.nil? || html_content.empty?
    
    # Basic HTML tag removal
    content = html_content.gsub(/<[^>]*>/, ' ')
    content = content.gsub(/&nbsp;/, ' ')
    content = content.gsub(/&amp;/, '&')
    content = content.gsub(/&lt;/, '<')
    content = content.gsub(/&gt;/, '>')
    content = content.gsub(/&quot;/, '"')
    content = content.gsub(/&#39;/, "'")
    content = content.gsub(/&#x27;/, "'")
    content = content.gsub(/&apos;/, "'")
    
    # Clean up extra whitespace
    content = content.gsub(/\s+/, ' ').strip
    
    # Return full content
    content
  end

  def format_document_data(document)
    # Extract basic info
    id = document['id'] || 'N/A'
    title = document['title'] || 'N/A'
    type = document['type'] || 'N/A'
    status = document['status'] || 'N/A'
    
    # Extract version info
    version = document.dig('version', 'number') || 'N/A'
    created_date = document.dig('version', 'when') || 'N/A'
    created_by = document.dig('version', 'by', 'displayName') || 'N/A'
    last_modified_by = document.dig('version', 'by', 'displayName') || 'N/A'
    
    # Extract space info
    space_name = document.dig('space', 'name') || 'N/A'
    space_key = document.dig('space', 'key') || 'N/A'
    
    # Extract ancestors (parent pages)
    ancestors = document['ancestors'] || []
    parent_titles = ancestors.map { |ancestor| ancestor['title'] }.join(' > ')
    parent_path = parent_titles.empty? ? 'Root Level' : parent_titles
    
    # Extract children pages if any
    children = document.dig('children', 'page', 'results') || []
    child_titles = children.map { |child| child['title'] }.join(', ')
    child_pages = child_titles.empty? ? 'None' : child_titles
    
    # Extract content
    content = 'Content not available'
    if document.dig('body', 'storage', 'value')
      raw_content = document.dig('body', 'storage', 'value')
      content = clean_html_content(raw_content)
    end
    
    # Build web URL
    web_url = "#{CONFLUENCE_BASE_URL}/wiki/spaces/#{space_key}/pages/#{id}"
    
    <<~DOC_FORMAT
      
      #{'=' * 80}
      Document ID: #{id}
      Title: #{title}
      Type: #{type}
      Status: #{status}
      Space: #{space_name} (#{space_key})
      Parent Path: #{parent_path}
      Child Pages: #{child_pages}
      Version: #{version}
      Created/Modified: #{created_date}
      Last Modified By: #{last_modified_by}
      URL: #{web_url}
      
      CONTENT:
      #{content}
      #{'=' * 80}
    DOC_FORMAT
  end

  def save_to_file(documents, filename)
    puts "\nSaving data to #{filename}..."
    
    File.open(filename, 'w', encoding: 'utf-8') do |file|
      # Write header
      file.puts 'CONFLUENCE DOCUMENTS DATA EXPORT'
      file.puts "Generated on: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      file.puts "Requested Document IDs: #{@document_ids.join(', ')}"
      file.puts '=' * 80
      file.puts
      
      # Write documents summary
      file.puts 'DOCUMENTS SUMMARY'
      file.puts "Total Documents Requested: #{@document_ids.length}"
      file.puts "Total Documents Retrieved: #{documents.length}"
      file.puts "Success Rate: #{documents.length}/#{@document_ids.length} (#{((documents.length.to_f / @document_ids.length) * 100).round(1)}%)"
      file.puts '=' * 80
      file.puts
      
      # Write individual documents
      if documents.empty?
        file.puts 'No documents were successfully retrieved.'
      else
        file.puts 'DETAILED DOCUMENTS'
        documents.each_with_index do |document, index|
          file.puts "\n[Document #{index + 1}/#{documents.length}]"
          file.puts format_document_data(document)
          file.puts
        end
      end
      
      # Write failed document IDs if any
      successful_ids = documents.map { |doc| doc['id'] }
      failed_ids = @document_ids - successful_ids
      
      unless failed_ids.empty?
        file.puts "\n" + '=' * 80
        file.puts 'FAILED DOCUMENT IDS'
        file.puts "The following document IDs could not be retrieved:"
        failed_ids.each { |id| file.puts "- #{id}" }
        file.puts '=' * 80
      end
    end
    
    puts "Data successfully saved to #{filename}"
    true
  rescue StandardError => e
    puts "Error saving to file: #{e.message}"
    false
  end

  def run
    puts 'Starting Confluence documents fetch by ID...'
    puts "Confluence URL: #{CONFLUENCE_BASE_URL}"
    puts "Output File: #{OUTPUT_FILE}"
    puts
    
    # Collect document IDs from user input
    unless collect_document_ids
      puts '❌ Cannot proceed without valid document IDs!'
      return
    end
    
    # Fetch all documents
    documents = fetch_all_documents
    
    # Save to file
    success = save_to_file(documents, OUTPUT_FILE)
    
    if success
      puts
      puts '✅ Export completed successfully!'
      puts "📁 Data saved to: #{OUTPUT_FILE}"
      puts "📊 Documents processed: #{@document_ids.length}"
      puts "📄 Documents retrieved: #{documents.length}"
      puts "📄 Full content included for all retrieved documents"
      
      if documents.length < @document_ids.length
        puts "⚠️  Some documents could not be retrieved. Check the file for details."
      end
    else
      puts
      puts '❌ Export failed!'
    end
  end
end

# Run the script if called directly
if __FILE__ == $PROGRAM_NAME
  fetcher = ConfluenceDocsFetcher.new
  fetcher.run
end
