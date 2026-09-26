import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import { AccessToken, TrackSource } from "npm:livekit-server-sdk@2.8.2";

type CallStatus = "ringing" | "accepted" | "ended" | "declined" | "missed";

type CallRow = {
  id: string;
  conversation_id: string;
  caller_id: string;
  callee_id: string;
  status: CallStatus;
  created_at: string;
  ended_at: string | null;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const livekitApiKey = Deno.env.get("LIVEKIT_API_KEY") ?? "";
const livekitApiSecret = Deno.env.get("LIVEKIT_API_SECRET") ?? "";
const livekitUrl = Deno.env.get("LIVEKIT_URL") ?? "";
const allowedOrigins = (Deno.env.get("ALLOWED_ORIGINS") ?? "")
  .split(",")
  .map((value) => value.trim())
  .filter(Boolean);

function corsHeaders(origin: string | null): HeadersInit {
  if (!origin) return {};
  if (allowedOrigins.length === 0 || !allowedOrigins.includes(origin)) {
    return {};
  }
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    Vary: "Origin",
  };
}

function json(
  status: number,
  body: Record<string, unknown>,
  origin: string | null,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(origin),
    },
  });
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function getCallId(payload: unknown): string | null {
  if (!isRecord(payload) || typeof payload.call_id !== "string") return null;
  const callId = payload.call_id.trim();
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
      .test(callId)
  ) {
    return null;
  }
  return callId;
}

function timestampMs(isoTimestamp: string): number | null {
  const value = new Date(isoTimestamp).getTime();
  return Number.isFinite(value) ? value : null;
}

function hasValidDates(call: CallRow): boolean {
  if (timestampMs(call.created_at) === null) return false;
  return call.ended_at === null || timestampMs(call.ended_at) !== null;
}

function ageMs(isoTimestamp: string): number {
  return Date.now() - (timestampMs(isoTimestamp) ?? Date.now());
}

function isOldRinging(call: CallRow): boolean {
  return call.status === "ringing" && ageMs(call.created_at) > 60_000;
}

function isStaleAccepted(call: CallRow): boolean {
  return call.status === "accepted" &&
    ageMs(call.created_at) > 2 * 60 * 60 * 1000;
}

async function handleRequest(req: Request): Promise<Response> {
  const origin = req.headers.get("Origin");

  if (origin && allowedOrigins.length > 0 && !allowedOrigins.includes(origin)) {
    return json(403, { error: "Origin is not allowed" }, origin);
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }
  if (req.method !== "POST") {
    return json(405, { error: "Use POST" }, origin);
  }

  if (
    !supabaseUrl || !supabaseAnonKey || !livekitApiKey || !livekitApiSecret ||
    !livekitUrl
  ) {
    return json(500, { error: "Server is not configured" }, origin);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const match = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!match) {
    return json(401, { error: "Bearer token is required" }, origin);
  }
  const jwt = match[1];

  const userClient = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser(
    jwt,
  );
  if (authError || !authData.user) {
    return json(401, { error: "Invalid Supabase session" }, origin);
  }

  let payload: unknown;
  try {
    payload = await req.json();
  } catch (_error) {
    return json(400, { error: "Invalid JSON" }, origin);
  }

  const callId = getCallId(payload);
  if (!callId) {
    return json(400, { error: "call_id is required" }, origin);
  }

  const { error: cleanupError } = await userClient.rpc(
    "expire_old_ringing_calls",
  );
  if (cleanupError) {
    return json(500, { error: "Call cleanup failed" }, origin);
  }

  const { data: call, error: callError } = await userClient
    .from("calls")
    .select(
      "id, conversation_id, caller_id, callee_id, status, created_at, ended_at",
    )
    .eq("id", callId)
    .single<CallRow>();

  if (callError || !call) {
    return json(404, { error: "Call was not found for this user" }, origin);
  }

  if (!hasValidDates(call)) {
    return json(500, { error: "Call data is invalid" }, origin);
  }

  const userId = authData.user.id;
  const isCaller = call.caller_id === userId;
  const isCallee = call.callee_id === userId;

  if (!isCaller && !isCallee) {
    return json(403, { error: "User is not a call actor" }, origin);
  }
  if (isOldRinging(call)) {
    return json(409, { error: "Ringing call expired" }, origin);
  }
  if (isStaleAccepted(call)) {
    return json(409, { error: "Accepted call expired" }, origin);
  }
  if (isCaller && call.status !== "ringing" && call.status !== "accepted") {
    return json(409, {
      error: "Caller can join only ringing or accepted calls",
    }, origin);
  }
  if (isCallee && call.status !== "accepted") {
    return json(409, { error: "Callee can join only accepted calls" }, origin);
  }

  const room = `voice-${call.id}`;
  const ttlSeconds = 300;
  const accessToken = new AccessToken(livekitApiKey, livekitApiSecret, {
    identity: userId,
    ttl: ttlSeconds,
  });

  accessToken.addGrant({
    room,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: false,
    canPublishSources: [TrackSource.MICROPHONE],
  });

  const token = await accessToken.toJwt();

  // Parent iOS client expects exactly these success keys.
  return json(200, { token, url: livekitUrl }, origin);
}

serve(async (req) => {
  const origin = req.headers.get("Origin");

  try {
    return await handleRequest(req);
  } catch (_error) {
    return json(500, { error: "Internal server error" }, origin);
  }
});
