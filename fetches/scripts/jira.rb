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
JIRA_BASE_URL = 'https://browserstack.atlassian.net' # Replace with your Jira instance URL
API_TOKEN = ENV['JIRA_API_TOKEN'] || 'your-api-token-here' # Set in environment or replace
EMAIL = ENV['JIRA_EMAIL'] || 'your-email@company.com' # Set in environment or replace
OUTPUT_FILE = 'jira_epic_data.txt'

class JiraEpicFetcher
  def initialize
    @credentials = Base64.strict_encode64("#{EMAIL}:#{API_TOKEN}")
    @jira_links = []
    @issue_keys = []
  end

  def extract_issue_keys_from_args
    # Check if Jira links were provided as command line arguments
    if ARGV.length > 0
      input = ARGV.join(' ')
      puts "📋 Processing Jira links from command line: #{input}"
      
      # Parse all arguments and handle comma-separated values
      all_entries = []
      ARGV.each do |arg|
        if arg.include?(',')
          # Split comma-separated entries
          all_entries.concat(arg.split(',').map(&:strip))
        else
          all_entries << arg.strip
        end
      end
      
      # Extract issue keys from various Jira URL formats
      issue_keys = []
      
      all_entries.each do |entry|
        next if entry.empty?
        
        # Handle different Jira URL formats
        if entry.match?(/https?:\/\/.*\.atlassian\.net/)
          # Extract issue key from URL
          if match = entry.match(/\/browse\/([A-Z0-9]+-\d+)/)
            issue_keys << match[1]
          elsif match = entry.match(/selectedIssue=([A-Z0-9]+-\d+)/)
            issue_keys << match[1]
          elsif match = entry.match(/\/([A-Z0-9]+-\d+)/)
            issue_keys << match[1]
          end
        elsif entry.match?(/^[A-Z0-9]+-\d+$/)
          # Direct issue key format (e.g., PROJ-123, A11Y-676)
          issue_keys << entry
        end
      end
      
      @issue_keys = issue_keys.uniq
      @jira_links = all_entries
      
      if @issue_keys.empty?
        puts '❌ No valid Jira issue keys found in command line arguments!'
        puts 'Expected formats:'
        puts '- Full URL: https://company.atlassian.net/browse/A11Y-676'
        puts '- Issue key: A11Y-676'
        puts '- Multiple: "URL1,URL2" or "KEY1,KEY2"'
        return false
      end
      
      puts "✅ Extracted #{@issue_keys.length} issue keys:"
      @issue_keys.each_with_index { |key, index| puts "   #{index + 1}. #{key}" }
      puts
      
      return true
    end
    
    false
  end

  def collect_jira_links_interactive
    puts '📋 Enter Jira Links or Issue Keys'
    puts 'You can enter in the following ways:'
    puts '1. Full Jira URL: https://company.atlassian.net/browse/PROJ-123'
    puts '2. Issue key: PROJ-123'
    puts '3. Multiple entries separated by spaces or commas'
    puts
    print 'Enter Jira links/keys: '
    
    input = STDIN.gets.chomp.strip
    
    if input.empty?
      puts '❌ No Jira links provided!'
      return false
    end
    
    # Parse input
    entries = []
    if input.include?(',')
      entries = input.split(',').map(&:strip)
    else
      entries = input.split(' ').map(&:strip)
    end
    
    # Extract issue keys
    issue_keys = []
    entries.each do |entry|
      if entry.match?(/https?:\/\/.*\.atlassian\.net/)
        # Extract from URL
        if match = entry.match(/\/browse\/([A-Z]+-\d+)/)
          issue_keys << match[1]
        elsif match = entry.match(/selectedIssue=([A-Z]+-\d+)/)
          issue_keys << match[1]
        end
      elsif entry.match?(/^[A-Z]+-\d+$/)
        # Direct issue key
        issue_keys << entry
      end
    end
    
    @issue_keys = issue_keys.uniq
    @jira_links = entries
    
    if @issue_keys.empty?
      puts '❌ No valid issue keys found!'
      return false
    end
    
    puts "✅ Extracted #{@issue_keys.length} issue keys:"
    @issue_keys.each_with_index { |key, index| puts "   #{index + 1}. #{key}" }
    puts
    
    true
  end

  def collect_jira_links
    # Try command line arguments first, then interactive input
    return true if extract_issue_keys_from_args
    collect_jira_links_interactive
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
      puts "Issue not found (404): #{url}"
      nil
    when '403'
      puts "Access denied (403): #{url}"
      nil
    else
      puts "Error: HTTP #{response.code} - #{response.message}"
      puts "Response body: #{response.body}" if response.body
      nil
    end
  rescue StandardError => e
    puts "Request failed: #{e.message}"
    nil
  end

  def fetch_issue(issue_key)
    puts "Fetching issue: #{issue_key}"
    issue_url = "#{JIRA_BASE_URL}/rest/api/3/issue/#{issue_key}"
    params = {
      'expand' => 'names,schema,operations,editmeta,changelog,renderedFields'
    }
    
    issue = make_request(issue_url, params)
    
    if issue
      puts "✅ Successfully fetched: #{issue['key']} - #{issue.dig('fields', 'summary') || 'No summary'}"
    else
      puts "❌ Failed to fetch issue: #{issue_key}"
    end
    
    issue
  rescue StandardError => e
    puts "Error fetching issue #{issue_key}: #{e.message}"
    nil
  end

  def fetch_epic_issues(epic_key)
    puts "Fetching child work items for: #{epic_key}"
    
    # Get child issues using the issue API with subtasks expansion
    children_issues = fetch_children_from_issue_api(epic_key)
    
    puts "✅ Total child work items found for #{epic_key}: #{children_issues.length}"
    children_issues
  rescue StandardError => e
    puts "Error fetching child work items for #{epic_key}: #{e.message}"
    []
  end

  def fetch_children_from_issue_api(issue_key)
    puts "  📋 Using Jira Agile API to fetch epic issues for #{issue_key}..."
    
    # Use the correct Jira Agile API endpoint for epic issues
    epic_issues_url = "#{JIRA_BASE_URL}/rest/agile/1.0/epic/#{issue_key}/issue"
    params = {
      'maxResults' => 100,
      'expand' => 'names,schema,operations,editmeta,changelog,renderedFields'
    }
    
    epic_data = make_request(epic_issues_url, params)
    return [] unless epic_data
    
    children = []
    
    # The Agile API returns issues directly in the 'issues' array
    if epic_data['issues']
      epic_issues = epic_data['issues'] || []
      puts "  ✅ Found #{epic_issues.length} epic issues via Agile API"
      
      epic_issues.each do |epic_issue|
        if epic_issue['key']
          puts "    Epic issue: #{epic_issue['key']} - #{epic_issue.dig('fields', 'summary') || 'No summary'}"
          children << epic_issue
        end
      end
    else
      puts "  ❌ No 'issues' field found in Agile API response"
      puts "  🔍 DEBUG: Available fields in Agile API response:"
      epic_data.keys.each do |key|
        puts "    #{key}: #{epic_data[key].class}"
      end
    end
    
    puts "  📊 Total epic issues found via Agile API: #{children.length}"
    children
  rescue StandardError => e
    puts "  ❌ Error with Agile API: #{e.message}"
    []
  end

  def fetch_children_from_search_api(epic_key)
    puts "  🔍 Trying JQL search for child work items of #{epic_key}..."
    
    all_issues = []
    
    # Try multiple JQL queries for different child work item relationships
    jql_queries = [
      "\"Epic Link\" = #{epic_key}",
      "parent = #{epic_key}",
      "\"Parent Link\" = #{epic_key}",
      "cf[10014] = #{epic_key}",
      "\"Epic Link\" = \"#{epic_key}\"",
      "parent = \"#{epic_key}\"",
      "\"Parent Link\" = \"#{epic_key}\"",
      "cf[10014] = \"#{epic_key}\"",
      "\"Epic Name\" = #{epic_key}",
      "\"Epic Name\" = \"#{epic_key}\"",
      "issue in childIssuesOf(#{epic_key})",
      "issue in childIssuesOf(\"#{epic_key}\")"
    ]
    
    jql_queries.each_with_index do |jql, index|
      puts "    Trying JQL #{index + 1}/#{jql_queries.length}: #{jql}"
      
      start_at = 0
      query_issues = []
      
      loop do
        # Try new JQL endpoint first
        search_url = "#{JIRA_BASE_URL}/rest/api/3/search/jql"
        request_body = {
          'jql' => jql,
          'startAt' => start_at,
          'maxResults' => 50,
          'expand' => ['names', 'schema', 'operations', 'editmeta', 'changelog', 'renderedFields']
        }
        
        result = make_jql_post_request(search_url, request_body)
        break unless result
        
        issues = result['issues'] || []
        break if issues.empty?
        
        query_issues.concat(issues)
        
        break if issues.length < 50
        start_at += 50
      end
      
      if query_issues.length > 0
        puts "    ✅ Found #{query_issues.length} issues with this JQL"
        all_issues.concat(query_issues)
      end
    end
    
    # Remove duplicates
    all_issues.uniq { |issue| issue['key'] }
  rescue StandardError => e
    puts "  ❌ Error with JQL search: #{e.message}"
    []
  end

  def fetch_subtasks(parent_key)
    puts "Fetching subtasks for: #{parent_key}"
    
    # Use the issue API to get subtasks directly
    issue_url = "#{JIRA_BASE_URL}/rest/api/3/issue/#{parent_key}"
    params = {
      'expand' => 'subtasks'
    }
    
    issue_data = make_request(issue_url, params)
    return [] unless issue_data
    
    subtasks_data = issue_data.dig('fields', 'subtasks') || []
    
    if subtasks_data.length > 0
      puts "✅ Found #{subtasks_data.length} subtasks for #{parent_key}"
      
      # Fetch full details for each subtask
      full_subtasks = []
      subtasks_data.each do |subtask|
        if subtask['key']
          full_subtask = fetch_issue(subtask['key'])
          full_subtasks << full_subtask if full_subtask
        end
      end
      
      return full_subtasks
    else
      puts "No subtasks found for #{parent_key}"
      return []
    end
  rescue StandardError => e
    puts "Error fetching subtasks for #{parent_key}: #{e.message}"
    []
  end

  def make_jql_post_request(url, body)
    uri = URI(url)
    
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri)
    create_auth_headers.each { |key, value| request[key] = value }
    request.body = body.to_json
    
    response = http.request(request)
    
    case response.code
    when '200'
      JSON.parse(response.body)
    when '400'
      puts "Bad request (400): #{url}"
      puts "Response body: #{response.body}" if response.body
      puts "Trying fallback method..."
      # Fallback to regular search endpoint
      fallback_url = url.gsub('/search/jql', '/search')
      make_request(fallback_url, {
        'jql' => body['jql'],
        'maxResults' => body['maxResults'],
        'expand' => body['expand'].is_a?(Array) ? body['expand'].join(',') : body['expand']
      })
    when '404'
      puts "Endpoint not found (404): #{url}"
      nil
    when '403'
      puts "Access denied (403): #{url}"
      nil
    when '410'
      puts "API deprecated (410): #{url}"
      puts "Trying fallback method..."
      # Fallback to regular search endpoint
      fallback_url = url.gsub('/search/jql', '/search')
      make_request(fallback_url, {
        'jql' => body['jql'],
        'maxResults' => body['maxResults'],
        'expand' => body['expand'].is_a?(Array) ? body['expand'].join(',') : body['expand']
      })
    else
      puts "Error: HTTP #{response.code} - #{response.message}"
      puts "Response body: #{response.body}" if response.body
      # Try fallback for any other error
      puts "Trying fallback method..."
      fallback_url = url.gsub('/search/jql', '/search')
      make_request(fallback_url, {
        'jql' => body['jql'],
        'maxResults' => body['maxResults'],
        'expand' => body['expand'].is_a?(Array) ? body['expand'].join(',') : body['expand']
      })
    end
  rescue StandardError => e
    puts "Request failed: #{e.message}"
    puts "Trying fallback method..."
    # Try fallback on any exception
    fallback_url = url.gsub('/search/jql', '/search')
    make_request(fallback_url, {
      'jql' => body['jql'],
      'maxResults' => body['maxResults'],
      'expand' => body['expand'].is_a?(Array) ? body['expand'].join(',') : body['expand']
    })
  end

  def format_issue_data(issue, level = 0)
    return "Issue data not available" unless issue
    
    fields = issue['fields'] || {}
    indent = '  ' * level
    
    # Extract basic info
    key = issue['key'] || 'N/A'
    summary = fields['summary'] || 'N/A'
    issue_type = fields.dig('issuetype', 'name') || 'N/A'
    status = fields.dig('status', 'name') || 'N/A'
    priority = fields.dig('priority', 'name') || 'N/A'
    
    # Extract people
    assignee = fields.dig('assignee', 'displayName') || 'Unassigned'
    reporter = fields.dig('reporter', 'displayName') || 'N/A'
    creator = fields.dig('creator', 'displayName') || 'N/A'
    
    # Extract dates
    created = fields['created'] || 'N/A'
    updated = fields['updated'] || 'N/A'
    resolved = fields['resolved'] || 'Not resolved'
    
    # Extract project info
    project_name = fields.dig('project', 'name') || 'N/A'
    project_key = fields.dig('project', 'key') || 'N/A'
    
    # Extract epic info
    epic_link = fields['customfield_10014'] || fields['parent'] || nil
    epic_name = epic_link ? (epic_link['key'] || epic_link) : 'N/A'
    
    # Extract story points
    story_points = fields['customfield_10016'] || 'N/A'
    
    # Extract sprint info
    sprint_field = fields['customfield_10020'] || []
    sprint_info = 'N/A'
    if sprint_field.is_a?(Array) && !sprint_field.empty?
      sprint_info = sprint_field.last.to_s.match(/name=([^,\]]+)/)&.captures&.first || 'N/A'
    end
    
    # Extract description
    description = 'No description'
    if fields['description']
      if fields['description'].is_a?(Hash)
        # New Atlassian Document Format
        description = extract_adf_text(fields['description'])
      else
        description = fields['description'].to_s
      end
      description = description[0..500] + '...' if description.length > 500
    end
    
    # Extract comments count
    comments_count = fields.dig('comment', 'total') || 0
    
    # Extract attachments count
    attachments_count = fields['attachment']&.length || 0
    
    # Build web URL
    web_url = "#{JIRA_BASE_URL}/browse/#{key}"
    
    <<~ISSUE_FORMAT
      #{indent}
      #{indent}#{'=' * 80}
      #{indent}Issue Key: #{key}
      #{indent}Summary: #{summary}
      #{indent}Type: #{issue_type}
      #{indent}Status: #{status}
      #{indent}Priority: #{priority}
      #{indent}Project: #{project_name} (#{project_key})
      #{indent}Epic: #{epic_name}
      #{indent}Story Points: #{story_points}
      #{indent}Sprint: #{sprint_info}
      #{indent}Assignee: #{assignee}
      #{indent}Reporter: #{reporter}
      #{indent}Creator: #{creator}
      #{indent}Created: #{created}
      #{indent}Updated: #{updated}
      #{indent}Resolved: #{resolved}
      #{indent}Comments: #{comments_count}
      #{indent}Attachments: #{attachments_count}
      #{indent}URL: #{web_url}
      #{indent}
      #{indent}Description:
      #{indent}#{description}
      #{indent}#{'=' * 80}
    ISSUE_FORMAT
  end

  def extract_adf_text(adf_content)
    return 'No content' unless adf_content.is_a?(Hash)
    
    text_parts = []
    extract_text_from_adf_node(adf_content, text_parts)
    text_parts.join(' ').strip
  end

  def extract_text_from_adf_node(node, text_parts)
    return unless node.is_a?(Hash)
    
    if node['text']
      text_parts << node['text']
    end
    
    if node['content'].is_a?(Array)
      node['content'].each { |child| extract_text_from_adf_node(child, text_parts) }
    end
  end

  def process_all_issues
    puts "Processing #{@issue_keys.length} main issues..."
    puts '=' * 80
    
    all_issues_data = []
    
    @issue_keys.each_with_index do |issue_key, index|
      puts "\n[#{index + 1}/#{@issue_keys.length}] Processing: #{issue_key}"
      
      # Fetch main issue
      main_issue = fetch_issue(issue_key)
      next unless main_issue
      
      issue_data = {
        main_issue: main_issue,
        epic_issues: [],
        subtasks: []
      }
      
      # Check if this is an epic and fetch its issues
      issue_type = main_issue.dig('fields', 'issuetype', 'name')
      if issue_type&.downcase&.include?('epic')
        puts "  📋 This is an Epic, fetching all epic issues..."
        issue_data[:epic_issues] = fetch_epic_issues(issue_key)
      end
      
      # Fetch subtasks for the main issue
      puts "  📝 Fetching subtasks..."
      issue_data[:subtasks] = fetch_subtasks(issue_key)
      
      # Also fetch subtasks for epic issues
      issue_data[:epic_issues].each do |epic_issue|
        epic_subtasks = fetch_subtasks(epic_issue['key'])
        issue_data[:subtasks].concat(epic_subtasks)
      end
      
      all_issues_data << issue_data
      
      # Add delay between main issues
      sleep(0.5) if index < @issue_keys.length - 1
    end
    
    all_issues_data
  end

  def save_to_file(all_issues_data, filename)
    puts "\nSaving data to #{filename}..."
    
    total_issues = all_issues_data.sum do |data|
      1 + data[:epic_issues].length + data[:subtasks].length
    end
    
    File.open(filename, 'w', encoding: 'utf-8') do |file|
      # Write header
      file.puts 'JIRA EPIC/ISSUE DATA EXPORT'
      file.puts "Generated on: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      file.puts "Requested Issues: #{@issue_keys.join(', ')}"
      file.puts "Original Links: #{@jira_links.join(', ')}"
      file.puts '=' * 80
      file.puts
      
      # Write summary
      file.puts 'EXPORT SUMMARY'
      file.puts "Main Issues Processed: #{@issue_keys.length}"
      file.puts "Total Issues Exported: #{total_issues}"
      file.puts '=' * 80
      file.puts
      
      # Write detailed data
      all_issues_data.each_with_index do |issue_data, index|
        main_issue = issue_data[:main_issue]
        epic_issues = issue_data[:epic_issues]
        subtasks = issue_data[:subtasks]
        
        file.puts "\n[MAIN ISSUE #{index + 1}/#{all_issues_data.length}]"
        file.puts format_issue_data(main_issue)
        
        # Write epic issues
        if epic_issues.length > 0
          file.puts "\n  📋 EPIC ISSUES (#{epic_issues.length} issues):"
          epic_issues.each_with_index do |epic_issue, epic_index|
            file.puts "\n  [Epic Issue #{epic_index + 1}/#{epic_issues.length}]"
            file.puts format_issue_data(epic_issue, 1)
          end
        end
        
        # Write subtasks
        if subtasks.length > 0
          file.puts "\n  📝 SUBTASKS (#{subtasks.length} subtasks):"
          subtasks.each_with_index do |subtask, sub_index|
            file.puts "\n  [Subtask #{sub_index + 1}/#{subtasks.length}]"
            file.puts format_issue_data(subtask, 1)
          end
        end
        
        file.puts "\n" + '=' * 100 + "\n"
      end
    end
    
    puts "Data successfully saved to #{filename}"
    puts "📊 Total issues exported: #{total_issues}"
    true
  rescue StandardError => e
    puts "Error saving to file: #{e.message}"
    false
  end

  def run
    puts 'Starting Jira Epic/Issue fetcher...'
    puts "Jira URL: #{JIRA_BASE_URL}"
    puts "Output File: #{OUTPUT_FILE}"
    puts
    
    # Collect Jira links
    unless collect_jira_links
      puts '❌ Cannot proceed without valid Jira links!'
      return
    end
    
    # Process all issues
    all_issues_data = process_all_issues
    
    if all_issues_data.empty?
      puts '❌ No issues were successfully processed!'
      return
    end
    
    # Save to file
    success = save_to_file(all_issues_data, OUTPUT_FILE)
    
    if success
      puts
      puts '✅ Export completed successfully!'
      puts "📁 Data saved to: #{OUTPUT_FILE}"
      puts "📊 Main issues processed: #{@issue_keys.length}"
    else
      puts
      puts '❌ Export failed!'
    end
  end
end

# Run the script if called directly
if __FILE__ == $PROGRAM_NAME
  fetcher = JiraEpicFetcher.new
  fetcher.run
end
