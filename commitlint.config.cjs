module.exports = {
  extends: ['@commitlint/config-conventional'],
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
