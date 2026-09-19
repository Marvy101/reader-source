import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { WebSocketLikeConstructor } from "@supabase/realtime-js";
import WebSocket from "ws";

import type { RuntimeConfig } from "./config.js";

export type ConfiguredRuntime = RuntimeConfig &
  Required<
    Pick<
      RuntimeConfig,
      "supabaseUrl" | "supabasePublishableKey" | "supabaseSecretKey"
    >
  >;

const authOptions = {
  autoRefreshToken: false,
  detectSessionInUrl: false,
  persistSession: false,
};

const websocketTransport = WebSocket as unknown as WebSocketLikeConstructor;

export function isConfigured(
  config: RuntimeConfig,
): config is ConfiguredRuntime {
  return Boolean(
    config.supabaseUrl &&
      config.supabasePublishableKey &&
      config.supabaseSecretKey,
  );
}

export async function isSupabaseReachable(
  config: ConfiguredRuntime,
  fetcher: typeof fetch = fetch,
): Promise<boolean> {
  try {
    const response = await fetcher(
      new URL("/auth/v1/health", config.supabaseUrl),
      {
        headers: { apikey: config.supabasePublishableKey },
        signal: AbortSignal.timeout(3_000),
      },
    );
    return response.ok;
  } catch {
    return false;
  }
}

export function createUserClient(
  config: ConfiguredRuntime,
  accessToken: string,
): SupabaseClient {
  return createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: authOptions,
    global: {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
    realtime: { transport: websocketTransport },
  });
}

export function createPublicClient(
  config: ConfiguredRuntime,
): SupabaseClient {
  return createClient(config.supabaseUrl, config.supabasePublishableKey, {
    auth: authOptions,
    realtime: { transport: websocketTransport },
  });
}

export function createAdminClient(
  config: ConfiguredRuntime,
): SupabaseClient {
  return createClient(config.supabaseUrl, config.supabaseSecretKey, {
    auth: authOptions,
    realtime: { transport: websocketTransport },
  });
}
