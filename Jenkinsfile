// The release job: promote a service dev → uat → prod, or roll one back.
// Run it from Jenkins with Build with Parameters; prod waits for an approval.
//
// The pipeline is promotePipeline in the platform shared library
// (jenkins-sonarqube/shared-library/vars/promotePipeline.groovy). This file
// only says which services exist and who may approve production.
//
// See docs/release.md.

@Library('platform') _

promotePipeline(
  services: [
    'auth-api'   : [team: 'api-service', smokePaths: ['/api/auth/health']],
    'core-api'   : [team: 'api-service', smokePaths: []],
    'client-side': [team: 'web-service', smokePaths: ['/']],
  ],
  // Jenkins user ids (comma-separated) allowed to approve a prod release.
  prodApprovers: 'admin',
)
