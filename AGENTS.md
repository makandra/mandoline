# Working on the mandoline guides

Mandoline is open source and published on GitHub. Everything that goes into this repo
(guides, scripts, docs, commit messages) is public and must be safe for anyone to read.

## Folding migration feedback into the guides

Feedback from real migrations comes from customer apps. Keep the lesson, drop where it came from:

- **No customer or project names.** Don't name the app a lesson came from, not even an internal
  makandra app. No repo names, repo paths or file paths from a real app (`<app>/spec/...`). Write
  "an app", "one migration" or "the reference apps" instead. This applies to commit messages too.
- **Scrub project-specific details from examples.** Replace domain models, routes, CSS classes, UI
  strings (especially German copy) and data values taken from a real app with neutral placeholders
  (`movie`, `user`, `'Save'`, `'Title'`). An example a customer or their users could recognize is
  too specific, even without a name.
- **No stories that identify an app.** Keep the rule and why it matters, but drop the details:
  counts ("7 of 40", "~30 sites across 14 files"), timelines ("red for weeks"), and which branch,
  MR or migration it happened on.
- **Don't explain app defects.** A guide may describe a test-suite or migration pitfall and how to
  fix it. It must not describe a bug, security gap or misconfiguration in an app's own code or
  production setup, nor how it was fixed. Leave such findings out of the guides; they belong in
  that project's issue tracker.
- **No internal infrastructure.** No internal hostnames, credentials, CI details or team processes
  beyond what's needed to run mandoline.

If a lesson can't be explained without one of these details, leave it out and tell the human.
