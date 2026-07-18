import { z } from "zod";

export const sendRequestSchema = z.object({
  username: z.string().min(1),
  message: z.string().max(140).optional(),
});
