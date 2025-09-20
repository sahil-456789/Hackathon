import { executeConfluenceScript } from "./confluence.js";
import { executeJiraScript } from "./jira.js";

console.log('=== Testing Confluence Script ===');
executeConfluenceScript(['4010409990'])
  .then(result => {
    console.log('Confluence Success:', JSON.stringify(result, null, 2));
  })
  .catch(error => {
    console.error('Confluence Error:', JSON.stringify(error, null, 2));
  });

console.log('\n=== Testing Jira Script ===');
executeJiraScript(['https://browserstack.atlassian.net/browse/A11Y-676'])
  .then(result => {
    console.log('Jira Success:', JSON.stringify(result, null, 2));
  })
  .catch(error => {
    console.error('Jira Error:', JSON.stringify(error, null, 2));
  });
