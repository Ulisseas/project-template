module.exports = {
  extends: ['@commitlint/config-conventional'],
  // Dependabot's generated messages are exempt from linting. Their shape is
  // fixed by .github/dependabot.yml (prefix "chore", scope "deps"/"deps-dev"),
  // but two things about them cannot be configured there and failed the
  // required commitlint check on every Dependabot PR:
  //   - the capital "Bump": Dependabot copies the subject case it finds in
  //     the repo's recent commits, and the "Co-authored-by: Claude" trailers
  //     on every squash commit here read as capitalised (dependabot-core,
  //     PrNamePrefixer#capitalise_first_word_from_previous_commits);
  //   - the header length: the reusable workflow's full path pushes every
  //     ulisseas/.github ci-telemetry bump past 100 characters.
  // Nothing in these messages needs linting: semantic-release reads type
  // "chore" and cuts no release. Hand-written commits are still linted.
  ignores: [(message) => /^chore\(deps(-dev)?\): [Bb]ump /.test(message)],
  rules: {
    // 100 is the conventional-commits default; Dependabot's grouped-update
    // titles run past 72 ("bump the <group> group across 1 directory with N updates").
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [2, 'always', 100],
    'type-enum': [2, 'always', [
      'feat',
      'fix',
      'docs',
      'style',
      'refactor',
      'perf',
      'test',
      'build',
      'ci',
      'chore',
      'revert',
    ]],
  },
};
