import argon2 from "argon2";

export function hashPassword(pw: string): Promise<string> {
  return argon2.hash(pw, { type: argon2.argon2id });
}

export function verifyPassword(hash: string, pw: string): Promise<boolean> {
  return argon2.verify(hash, pw);
}
