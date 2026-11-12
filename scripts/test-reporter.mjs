import { writeFileSync } from 'node:fs';
import { redact, redactValue } from './test-secrets.mjs';

// serialize only limited diagnostic fields.
// never expose raw test results, errors or steps to reporters.
export default class SafeReporter {
  constructor(options) { this.file = options.outputFile; this.results = []; }
  onStdOut(chunk) { process.stdout.write(redact(chunk.toString())); }
  onStdErr(chunk) { process.stderr.write(redact(chunk.toString())); }
  onError(error) { process.stderr.write(`${redact(error.stack || error.message || 'Playwright error')}\n`); }
  onTestEnd(test, result) {
    const steps = items => items.map(step => ({ title: step.title, category: step.category,
      location: step.location, error: step.error, steps: steps(step.steps) }));
    const safe = redactValue({ title: test.titlePath(), status: result.status, duration: result.duration,
      errors: result.errors, steps: steps(result.steps) });
    this.results.push(safe);
    console.log(`${safe.status}: ${safe.title.join(' > ')}`);
    for (const error of safe.errors) console.log(error.stack || error.message || 'test failed');
  }
  onEnd(result) {
    writeFileSync(this.file, JSON.stringify(redactValue({ status: result.status, tests: this.results }), null, 2), { mode: 0o600 });
    console.log(`Playwright: ${result.status}; ${this.results.length} tests`);
  }
}
