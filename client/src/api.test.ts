import { beforeEach, describe, expect, test, vi } from "vitest";
import { api, getTokens, setTokens } from "./api";

describe("API client", () => {
  beforeEach(() => { sessionStorage.clear(); setTokens(null); vi.restoreAllMocks(); });

  test("persists tokens only for the browser session", () => {
    setTokens({ accessToken: "access", refreshToken: "refresh" });
    expect(getTokens()).toEqual({ accessToken: "access", refreshToken: "refresh" });
    expect(localStorage.getItem("penguinchat.tokens")).toBeNull();
  });

  test("adds bearer auth and loads contacts", async () => {
    setTokens({ accessToken: "access", refreshToken: "refresh" });
    const fetchMock = vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("[]", { status: 200, headers: { "Content-Type": "application/json" } }));
    await expect(api.contacts()).resolves.toEqual([]);
    expect(fetchMock).toHaveBeenCalledWith("/api/contacts", expect.objectContaining({ headers: expect.objectContaining({ Authorization: "Bearer access" }) }));
    const headers = fetchMock.mock.calls[0][1]?.headers as Record<string, string>;
    expect(headers["Content-Type"]).toBeUndefined();
  });
});
