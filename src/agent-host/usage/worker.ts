// Entry of the usage worker, a worker_threads thread of the agent host that owns the usage
// database and reads the agents' logs. Main builds it with `?modulePath` and passes its path in
// `host:init`.

import { parentPort, workerData } from 'node:worker_threads'
import type { PriceFiles, UsageRequest } from './protocol'
import { LOG_READERS } from './readers'
import { startUsageService } from './service'

const port = parentPort!
const data = workerData as { file: string; prices?: PriceFiles }
const handle = startUsageService(
  data.file,
  LOG_READERS,
  (reply) => port.postMessage(reply),
  undefined,
  data.prices,
)
port.on('message', (request: UsageRequest) => handle(request))
