export type RuntimeConfig = {
  supabaseUrl?: string;
  supabasePublishableKey?: string;
  supabaseSecretKey?: string;
  googleBooksApiKey?: string;
};

function present(value: string | undefined): string | undefined {
  const normalized = value?.trim();
  return normalized ? normalized : undefined;
}

export function readConfig(
  environment: NodeJS.ProcessEnv = process.env,
): RuntimeConfig {
  return {
    supabaseUrl: present(environment.SUPABASE_URL),
    supabasePublishableKey: present(environment.SUPABASE_PUBLISHABLE_KEY),
    supabaseSecretKey: present(environment.SUPABASE_SECRET_KEY),
    googleBooksApiKey: present(environment.GOOGLE_BOOKS_API_KEY),
  };
}

export function missingRequiredConfig(config: RuntimeConfig): string[] {
  const missing: string[] = [];

  if (!config.supabaseUrl) missing.push("SUPABASE_URL");
  if (!config.supabasePublishableKey) {
    missing.push("SUPABASE_PUBLISHABLE_KEY");
  }
  if (!config.supabaseSecretKey) missing.push("SUPABASE_SECRET_KEY");

  return missing;
}
