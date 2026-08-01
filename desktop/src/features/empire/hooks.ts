import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import type {
  AgentRuntimeSource,
  SnapshotEnvelope,
} from "@/features/empire/lib/cockpitModel";
import { listManagedAgentRuntimes } from "@/shared/api/tauriManagedAgents";
import {
  readEmpireSnapshot,
  refreshEmpireSnapshot,
} from "@/shared/api/tauriEmpire";

export const EMPIRE_SNAPSHOT_KEY = ["empire", "snapshot"] as const;
export const EMPIRE_AGENTS_KEY = ["empire", "agent-runtimes"] as const;

/**
 * The snapshot behind the cockpit.
 *
 * `staleTime: Infinity` + no refetch interval is deliberate: the snapshot only
 * changes when the collector runs, and the collector costs one GitHub query per
 * repo. Opening the tab reads the file once; everything beyond that is the
 * refresh button.
 */
export function useEmpireSnapshotQuery() {
  return useQuery<SnapshotEnvelope>({
    queryKey: EMPIRE_SNAPSHOT_KEY,
    queryFn: readEmpireSnapshot,
    staleTime: Number.POSITIVE_INFINITY,
    refetchOnWindowFocus: false,
    // One retry only. A second failure is information the user needs to see,
    // not something to keep hidden behind a spinner.
    retry: 1,
  });
}

/**
 * Managed-agent runtime, straight from this desktop process.
 *
 * Errors are surfaced as `state: "error"` rather than swallowed — the agents
 * tile must be able to say "not reachable" instead of showing zero agents.
 */
export function useEmpireAgentRuntimes() {
  const query = useQuery({
    queryKey: EMPIRE_AGENTS_KEY,
    queryFn: listManagedAgentRuntimes,
    staleTime: 15_000,
    refetchOnWindowFocus: false,
    retry: 1,
  });

  const source: AgentRuntimeSource | null = query.isPending
    ? null
    : query.isError
      ? {
          state: "error",
          message:
            query.error instanceof Error
              ? query.error.message
              : String(query.error),
        }
      : { state: "ok", runtimes: query.data ?? [] };

  return { ...query, source };
}

/** Runs the collector, then replaces the cached envelope with its result. */
export function useRefreshEmpireSnapshot() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: refreshEmpireSnapshot,
    onSuccess: (envelope) => {
      queryClient.setQueryData(EMPIRE_SNAPSHOT_KEY, envelope);
      void queryClient.invalidateQueries({ queryKey: EMPIRE_AGENTS_KEY });
    },
  });
}
