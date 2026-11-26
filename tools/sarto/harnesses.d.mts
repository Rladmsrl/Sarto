// Types of harnesses.mjs for the tests that check its manifest against the daemon's reader.

export interface CheckResult {
  harness: string
  version: string
  status: 'pass' | 'fail'
  failures: number
}

export interface HarnessChecks {
  generatedAt: string
  results: CheckResult[]
}

export interface Rule {
  sarto: string
  recommended?: string
  broken: string[]
  sha256: Record<string, string>
}

export interface ManifestDocument {
  sequence: number
  updatedAt: string
  harnesses: Record<string, Rule[]>
}

export function buildHarnessManifest(checks: HarnessChecks): ManifestDocument

export function signHarnessManifest(document: ManifestDocument): {
  envelope: { payload: string; signature: string }
  body: string
}
