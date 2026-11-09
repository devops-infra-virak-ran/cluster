// Load test for an environment's public site, through DNS, the ALB and TLS.
//
//   make load-test WORKSPACE=dev                     50 users, 3 minutes
//   make load-test WORKSPACE=dev VUS=100 HOLD=5m
//
// Ramps up, holds, ramps down — long enough for the HPA to add pods (it
// scales on CPU averaged over its sync period) and to show whether response
// time and errors hold while it does. The summary at the end is the result:
// p95 response time, error rate, requests per second.
//
// Fails (non-zero exit) when more than 1% of requests fail or p95 exceeds
// 1.5s — the availability and latency bar for the brief's performance test.

import http from 'k6/http';
import { check, sleep } from 'k6';

const vus = Number(__ENV.VUS || 50);
const base = __ENV.BASE_URL;

export const options = {
  stages: [
    { duration: '30s', target: vus },
    { duration: __ENV.HOLD || '3m', target: vus },
    { duration: '30s', target: 0 },
  ],
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1500'],
  },
};

export default function () {
  const page = http.get(`${base}/`, { tags: { route: '/' } });
  check(page, { 'site answers 200': (r) => r.status === 200 });
  sleep(0.2);
}
