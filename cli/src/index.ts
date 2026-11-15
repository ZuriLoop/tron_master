export { main } from "./cli.js";
export {
  createGovernanceWatcher,
  diffGovernance,
  readGovernance,
  inspectImplementation,
  type GovernanceAlert,
  type GovernanceSnapshot,
  type AlertKind,
  type Severity,
} from "./watcher.js";
export { deployFactory, validateFactoryConfig, encodeConstructor, type FactoryConfig } from "./deploy.js";
