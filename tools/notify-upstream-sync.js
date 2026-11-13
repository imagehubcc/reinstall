// Runs only from the trusted workflow revision, never from the candidate tree.
const title = 'Upstream sync requires attention';
const marker = '<!-- upstream-sync-attention -->';
const {owner, repo} = context.repo;
const url = `${context.serverUrl}/${owner}/${repo}/actions/runs/${context.runId}`;
const jobs = JSON.parse(process.env.JOB_RESULTS);
const summary = Object.entries(jobs).map(([name, value]) => `- ${name}: ${value.result}`).join('\n');
const body = `${marker}\nAutomatic upstream synchronization did not finish successfully. The sync workflow did not update main.\n\n${summary}\n\n[Workflow logs](${url})\n\nResolve the conflict or failure, then rerun the workflow. Server credentials are not used by this workflow.`;
const issues = await github.paginate(github.rest.issues.listForRepo, {owner, repo, state: 'open', per_page: 100});
const existing = issues.find(x => !x.pull_request && x.title === title && x.body?.includes(marker));
if (existing) {
  await github.rest.issues.update({owner, repo, issue_number: existing.number, body});
} else {
  await github.rest.issues.create({owner, repo, title, body, assignees: [owner]});
}
