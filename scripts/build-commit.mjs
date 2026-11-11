const gitObjectId = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/i;

export const buildCommitFrom = (environment) => {
  const sha = environment.GITHUB_SHA;
  return typeof sha === 'string' && gitObjectId.test(sha) ? sha.slice(0, 8) : 'development';
};

export const injectBuildCommit = (source, commit) => {
  if (!source.includes('BUILD_COMMIT')) throw new Error('staged base template is missing BUILD_COMMIT');
  return source.replaceAll('BUILD_COMMIT', commit);
};
