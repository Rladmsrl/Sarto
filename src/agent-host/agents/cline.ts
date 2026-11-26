import type { AgentDefinition } from '../catalog'

export const CLINE: AgentDefinition = {
  id: 'cline',
  name: 'Cline',
  registryId: 'cline',
  // The SDK its CLI is built on, which the package brings and Cline marks experimental: checked
  // on 3.0.74 (@cline/sdk 0.2.0). `--acp` runs for any other version, or when it does not start.
  preferred: { protocol: 'cline-sdk', checked: '>=3.0.74 <3.1.0' },
  launch: {
    kind: 'package',
    package: 'cline',
    args: ['--acp'],
    // Sarto keeps the installed version, so the CLI's own `npm update -g cline` on exit stays off.
    env: { CLINE_NO_AUTO_UPDATE: '1' },
  },
  requiresNode: '>=22',
  install: { hint: 'detect.hint.node', url: 'https://nodejs.org/en/download' },
}
