import { v5 as uuidv5 } from "uuid";

// Fixed namespace — never regenerate (see Global Constraints).
// NOTE: brief specified "6f9619ff-8b86-d011-b42d-00c04fc964ff" which is not a
// valid UUID (version nibble must be 1-5, got "d"); corrected to "1011" here.
const NAMESPACE = "6f9619ff-8b86-1011-b42d-00c04fc964ff";

/** Deterministic conversation id for a user pair, independent of argument order. */
export function conversationId(a: string, b: string): string {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  return uuidv5(`${lo}:${hi}`, NAMESPACE);
}
