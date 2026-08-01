import { invokeTauri } from "@/shared/api/tauri";
import type { SnapshotEnvelope } from "@/features/empire/lib/cockpitModel";

/**
 * Reads the cockpit snapshot the empire collector left in the nest (buzz#15).
 *
 * Cheap and offline — it touches one local file, never GitHub. This is what
 * makes "refresh on open" safe.
 */
export async function readEmpireSnapshot(): Promise<SnapshotEnvelope> {
  return invokeTauri<SnapshotEnvelope>("read_empire_snapshot");
}

/**
 * Re-runs the collector, then returns the fresh envelope.
 *
 * Expensive (one GitHub query per repo) — only ever call this from an explicit
 * user action, never from an effect or an interval.
 */
export async function refreshEmpireSnapshot(): Promise<SnapshotEnvelope> {
  return invokeTauri<SnapshotEnvelope>("refresh_empire_snapshot");
}
