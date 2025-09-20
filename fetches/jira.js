import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Parse failure reasons from Ruby script output for Jira
 * @param {string} output - Ruby script stdout
 * @returns {Array<Object>} - Array of failure reasons with issue keys
 */
function parseJiraFailureReasons(output) {
  const failures = [];
  const lines = output.split('\n');
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    
    // Look for failure patterns
    if (line.includes('❌ Failed to fetch issue:')) {
      const issueMatch = line.match(/issue: ([A-Z0-9]+-\d+)/);
      if (issueMatch) {
        const issueKey = issueMatch[1];
        let reason = 'Unknown error';
        
        // Look for the reason in previous lines
        for (let j = Math.max(0, i - 5); j < i; j++) {
          const prevLine = lines[j].trim();
          if (prevLine.includes('Access denied (403)')) {
            reason = 'Access denied (403) - Invalid credentials or insufficient permissions';
            break;
          } else if (prevLine.includes('Issue not found (404)')) {
            reason = 'Issue not found (404) - Issue does not exist or has been deleted';
            break;
          } else if (prevLine.includes('Error: HTTP')) {
            const httpMatch = prevLine.match(/Error: HTTP (\d+) - (.+)/);
            if (httpMatch) {
              reason = `HTTP ${httpMatch[1]} - ${httpMatch[2]}`;
            }
            break;
          } else if (prevLine.includes('Request failed')) {
            reason = 'Network error - Request failed to complete';
            break;
          }
        }
        
        failures.push({
          issueKey: issueKey,
          reason: reason,
          category: categorizeJiraError(reason)
        });
      }
    }
  }
  
  return failures;
}

/**
 * Parse success count from Ruby script output for Jira
 * @param {string} output - Ruby script stdout
 * @returns {number} - Number of successful fetches
 */
function parseJiraSuccessCount(output) {
  // Count successful fetches by looking for "✅ Successfully fetched:" lines
  const successLines = output.split('\n').filter(line => 
    line.includes('✅ Successfully fetched:')
  );
  return successLines.length;
}

/**
 * Parse processed issue keys from output
 * @param {string} output - Ruby script stdout
 * @returns {Array<string>} - Array of processed issue keys
 */
function parseProcessedIssueKeys(output) {
  const keys = [];
  const lines = output.split('\n');
  
  for (const line of lines) {
    if (line.includes('✅ Extracted') && line.includes('issue keys:')) {
      // Find the section that lists the issue keys
      const startIndex = lines.indexOf(line);
      for (let i = startIndex + 1; i < lines.length; i++) {
        const keyLine = lines[i].trim();
        if (keyLine.match(/^\d+\.\s+([A-Z0-9]+-\d+)$/)) {
          const match = keyLine.match(/^\d+\.\s+([A-Z0-9]+-\d+)$/);
          if (match) {
            keys.push(match[1]);
          }
        } else if (keyLine === '' || !keyLine.match(/^\d+\./)) {
          break;
        }
      }
      break;
    }
  }
  
  return keys;
}

/**
 * Categorize Jira error types for better understanding
 * @param {string} reason - Error reason
 * @returns {string} - Error category
 */
function categorizeJiraError(reason) {
  if (reason.includes('403') || reason.includes('Access denied')) {
    return 'AUTHENTICATION_ERROR';
  } else if (reason.includes('404') || reason.includes('not found')) {
    return 'ISSUE_NOT_FOUND';
  } else if (reason.includes('Network error') || reason.includes('Request failed')) {
    return 'NETWORK_ERROR';
  } else if (reason.includes('HTTP 500')) {
    return 'SERVER_ERROR';
  } else if (reason.includes('HTTP 429')) {
    return 'RATE_LIMIT_ERROR';
  } else {
    return 'UNKNOWN_ERROR';
  }
}

/**
 * Executes the jira.rb script with an array of Jira links or issue keys
 * @param {Array<string>|string} jiraLinks - Array of Jira links/keys or single link/key
 * @returns {Promise<Object>} - Promise that resolves with success/error response
 */
export async function executeJiraScript(jiraLinks) {
  return new Promise((resolve, reject) => {
    // Normalize input to array
    let linksArray;
    if (typeof jiraLinks === 'string') {
      linksArray = [jiraLinks];
    } else if (Array.isArray(jiraLinks)) {
      linksArray = jiraLinks;
    } else {
      return reject({
        success: false,
        error: 'Invalid input: jiraLinks must be a string or array',
        details: 'Expected a Jira link/key or array of Jira links/keys'
      });
    }

    if (linksArray.length === 0) {
      return reject({
        success: false,
        error: 'Empty input provided',
        details: 'At least one Jira link or issue key is required'
      });
    }

    // Validate and clean links/keys
    const validLinks = linksArray
      .map(link => String(link).trim())
      .filter(link => {
        if (!link) return false;
        // Accept Jira URLs or issue key format (e.g., PROJ-123, A11Y-676)
        return link.match(/https?:\/\/.*\.atlassian\.net/) || 
               link.match(/^[A-Z0-9]+-\d+$/);
      });

    if (validLinks.length === 0) {
      return reject({
        success: false,
        error: 'No valid Jira links or issue keys found',
        details: 'Jira links must be valid Atlassian URLs or issue keys (e.g., PROJ-123)'
      });
    }

    if (validLinks.length !== linksArray.length) {
      const invalidLinks = linksArray.filter(link => !validLinks.includes(String(link).trim()));
      console.warn(`Warning: Skipped invalid Jira links/keys: ${invalidLinks.join(', ')}`);
    }

    // Path to the Ruby script
    const scriptPath = path.join(__dirname, 'scripts', 'jira.rb');
    
    // Prepare command arguments
    const args = validLinks;
    
    console.log(`Executing Jira script with links/keys: ${validLinks.join(', ')}`);
    
    // Spawn the Ruby process
    const rubyProcess = spawn('ruby', [scriptPath, ...args], {
      cwd: path.join(__dirname, 'scripts'),
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let stdout = '';
    let stderr = '';

    // Collect stdout data
    rubyProcess.stdout.on('data', (data) => {
      const output = data.toString();
      stdout += output;
      console.log(`Ruby script output: ${output.trim()}`);
    });

    // Collect stderr data
    rubyProcess.stderr.on('data', (data) => {
      const error = data.toString();
      stderr += error;
      console.error(`Ruby script error: ${error.trim()}`);
    });

    // Handle process completion
    rubyProcess.on('close', (code) => {
      if (code === 0) {
        // Parse output to check for failures and extract reasons
        const failureReasons = parseJiraFailureReasons(stdout);
        const successCount = parseJiraSuccessCount(stdout);
        const processedKeys = parseProcessedIssueKeys(stdout);
        const totalProcessed = processedKeys.length || validLinks.length;
        
        // Success (script ran successfully, but may have issue fetch failures)
        const response = {
          success: true,
          message: 'Jira script executed successfully',
          inputLinks: validLinks,
          processedIssueKeys: processedKeys,
          totalProcessed: totalProcessed,
          successfulFetches: successCount,
          failedFetches: Math.max(0, totalProcessed - successCount),
          output: stdout.trim(),
          outputFile: 'jira_epic_data.txt'
        };

        // Add failure reasons if any issues failed to fetch
        if (failureReasons.length > 0) {
          response.failureReasons = failureReasons;
          response.warning = 'Some issues could not be retrieved. Check failureReasons for details.';
        }

        resolve(response);
      } else {
        // Error
        reject({
          success: false,
          error: `Ruby script exited with code ${code}`,
          details: stderr.trim() || stdout.trim() || 'Unknown error occurred',
          inputLinks: validLinks,
          exitCode: code
        });
      }
    });

    // Handle process errors (e.g., Ruby not found)
    rubyProcess.on('error', (error) => {
      reject({
        success: false,
        error: 'Failed to execute Ruby script',
        details: error.message,
        possibleCauses: [
          'Ruby is not installed on the system',
          'Ruby is not in the system PATH',
          'Script file permissions issue',
          'Script file not found'
        ]
      });
    });

    // Set a timeout to prevent hanging (optional, 10 minutes for Jira as it can be slower)
    const timeout = setTimeout(() => {
      rubyProcess.kill('SIGTERM');
      reject({
        success: false,
        error: 'Script execution timeout',
        details: 'Ruby script took longer than 10 minutes to complete',
        inputLinks: validLinks
      });
    }, 10 * 60 * 1000); // 10 minutes

    // Clear timeout when process completes
    rubyProcess.on('close', () => {
      clearTimeout(timeout);
    });
  });
}

/**
 * Wrapper function for easier usage with error handling
 * @param {Array<string>|string} jiraLinks - Array of Jira links/keys or single link/key
 * @returns {Promise<Object>} - Promise that always resolves with success/error status
 */
export async function fetchJiraIssues(jiraLinks) {
  try {
    const result = await executeJiraScript(jiraLinks);
    return result;
  } catch (error) {
    console.error('Jira script execution failed:', error);
    return error;
  }
}

// Example usage (commented out):
/*
// Usage examples:

// Single epic link
const result1 = await fetchJiraIssues('https://company.atlassian.net/browse/A11Y-676');

// Single issue key
const result2 = await fetchJiraIssues('A11Y-676');

// Multiple links/keys
const result3 = await fetchJiraIssues([
  'https://company.atlassian.net/browse/A11Y-676',
  'PROJ-123',
  'https://company.atlassian.net/browse/EPIC-456'
]);

// With error handling
try {
  const result = await executeJiraScript(['A11Y-676', 'PROJ-123']);
  console.log('Success:', result);
  
  if (result.failureReasons) {
    result.failureReasons.forEach(failure => {
      console.log(`Issue ${failure.issueKey}: ${failure.reason}`);
    });
  }
} catch (error) {
  console.error('Error:', error);
}
*/
