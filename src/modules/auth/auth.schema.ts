import { z } from "zod";

export const registerSchema = z.object({
  username: z.string().min(3).max(32).regex(/^[a-zA-Z0-9_]+$/),
  display_name: z.string().min(1).max(48),
  password: z.string().min(6).max(128),
});

export const loginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

export const refreshSchema = z.object({
  refreshToken: z.string().min(1),
});

export const updateMeSchema = z.object({
  display_name: z.string().min(1).max(48).optional(),
  signature: z.string().max(140).optional(),
  avatar_url: z.string().url().max(500).optional(),
});
