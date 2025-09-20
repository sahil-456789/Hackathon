import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Parse failure reasons from Ruby script output
 * @param {string} output - Ruby script stdout
 * @returns {Array<Object>} - Array of failure reasons with document IDs
 */
function parseFailureReasons(output) {
  const failures = [];
  const lines = output.split('\n');
  
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    
    // Look for failure patterns
    if (line.includes('❌ Failed to fetch document ID:')) {
      const docIdMatch = line.match(/document ID: (\d+)/);
      if (docIdMatch) {
        const docId = docIdMatch[1];
        let reason = 'Unknown error';
        
        // Look for the reason in previous lines
        for (let j = Math.max(0, i - 5); j < i; j++) {
          const prevLine = lines[j].trim();
          if (prevLine.includes('Access denied (403)')) {
            reason = 'Access denied (403) - Invalid credentials or insufficient permissions';
            break;
          } else if (prevLine.includes('Document not found (404)')) {
            reason = 'Document not found (404) - Document does not exist or has been deleted';
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
          documentId: docId,
          reason: reason,
          category: categorizeError(reason)
        });
      }
    }
  }
  
  return failures;
}

/**
 * Parse success count from Ruby script output
 * @param {string} output - Ruby script stdout
 * @returns {number} - Number of successful fetches
 */
function parseSuccessCount(output) {
  const successMatch = output.match(/✅ Successful: (\d+)/);
  return successMatch ? parseInt(successMatch[1], 10) : 0;
}

/**
 * Categorize error types for better understanding
 * @param {string} reason - Error reason
 * @returns {string} - Error category
 */
function categorizeError(reason) {
  if (reason.includes('403') || reason.includes('Access denied')) {
    return 'AUTHENTICATION_ERROR';
  } else if (reason.includes('404') || reason.includes('not found')) {
    return 'DOCUMENT_NOT_FOUND';
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
 * Executes the confluence.rb script with an array of confluence document IDs
 * @param {Array<string|number>} confluenceIds - Array of confluence document IDs
 * @returns {Promise<Object>} - Promise that resolves with success/error response
 */
export async function executeConfluenceScript(confluenceIds) {
  return new Promise((resolve, reject) => {
    // Validate input
    if (!Array.isArray(confluenceIds)) {
      return reject({
        success: false,
        error: 'Invalid input: confluenceIds must be an array',
        details: 'Expected an array of confluence document IDs'
      });
    }

    if (confluenceIds.length === 0) {
      return reject({
        success: false,
        error: 'Empty array provided',
        details: 'At least one confluence document ID is required'
      });
    }

    // Validate and clean IDs
    const validIds = confluenceIds
      .map(id => String(id).trim())
      .filter(id => id && /^\d+$/.test(id));

    if (validIds.length === 0) {
      return reject({
        success: false,
        error: 'No valid confluence IDs found',
        details: 'Confluence IDs must be numeric strings or numbers'
      });
    }

    if (validIds.length !== confluenceIds.length) {
      const invalidIds = confluenceIds.filter(id => !validIds.includes(String(id).trim()));
      console.warn(`Warning: Skipped invalid confluence IDs: ${invalidIds.join(', ')}`);
    }

    // Path to the Ruby script
    const scriptPath = path.join(__dirname, 'scripts', 'confluence.rb');
    
    // Prepare command arguments
    const args = validIds;
    
    console.log(`Executing confluence script with IDs: ${validIds.join(', ')}`);
    
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
        const failureReasons = parseFailureReasons(stdout);
        const successCount = parseSuccessCount(stdout);
        const totalProcessed = validIds.length;
        
        // Success (script ran successfully, but may have document fetch failures)
        const response = {
          success: true,
          message: 'Confluence script executed successfully',
          processedIds: validIds,
          totalProcessed: totalProcessed,
          successfulFetches: successCount,
          failedFetches: totalProcessed - successCount,
          output: stdout.trim(),
          outputFile: 'confluence_documents_data.txt'
        };

        // Add failure reasons if any documents failed to fetch
        if (failureReasons.length > 0) {
          response.failureReasons = failureReasons;
          response.warning = 'Some documents could not be retrieved. Check failureReasons for details.';
        }

        resolve(response);
      } else {
        // Error
        reject({
          success: false,
          error: `Ruby script exited with code ${code}`,
          details: stderr.trim() || stdout.trim() || 'Unknown error occurred',
          processedIds: validIds,
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

    // Set a timeout to prevent hanging (optional, 5 minutes)
    const timeout = setTimeout(() => {
      rubyProcess.kill('SIGTERM');
      reject({
        success: false,
        error: 'Script execution timeout',
        details: 'Ruby script took longer than 5 minutes to complete',
        processedIds: validIds
      });
    }, 5 * 60 * 1000); // 5 minutes

    // Clear timeout when process completes
    rubyProcess.on('close', () => {
      clearTimeout(timeout);
    });
  });
}

/**
 * Wrapper function for easier usage with error handling
 * @param {Array<string|number>} confluenceIds - Array of confluence document IDs
 * @returns {Promise<Object>} - Promise that always resolves with success/error status
 */
export async function fetchConfluenceDocuments(confluenceIds) {
  try {
    const result = await executeConfluenceScript(confluenceIds);
    return result;
  } catch (error) {
    console.error('Confluence script execution failed:', error);
    return error;
  }
}

// Example usage (commented out):
/*
// Usage examples:

// Basic usage
const result = await fetchConfluenceDocuments(['123456789', '987654321']);
console.log(result);

// With error handling
try {
  const result = await executeConfluenceScript(['123456789', '987654321']);
  console.log('Success:', result);
} catch (error) {
  console.error('Error:', error);
}

// Mixed valid/invalid IDs
const result2 = await fetchConfluenceDocuments(['123456789', 'invalid', '987654321', '']);
console.log(result2); // Will process only valid IDs and warn about invalid ones
*/
