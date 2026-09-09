// Thin fetch wrapper: attaches the bearer token, JSON-encodes bodies, and
// normalizes errors. Kept dependency-free (no build step) on purpose.
const API = {
  TOKEN_KEY: "giftpay_token",
  COOKIE_TOKEN_KEY: "giftpay_session",

  getCookie(name) {
    const prefix = name + "=";
    return document.cookie
      .split(";")
      .map((part) => part.trim())
      .find((part) => part.startsWith(prefix))
      ?.slice(prefix.length) || null;
  },

  getToken() {
    return localStorage.getItem(this.TOKEN_KEY) || this.getCookie(this.COOKIE_TOKEN_KEY);
  },
  setToken(token) {
    if (token) localStorage.setItem(this.TOKEN_KEY, token);
    else localStorage.removeItem(this.TOKEN_KEY);
  },
  isLoggedIn() {
    return !!this.getToken();
  },

  async request(method, path, body) {
    const headers = { "Content-Type": "application/json" };
    const token = this.getToken();
    if (token) headers["Authorization"] = "Bearer " + token;

    const res = await fetch(path, {
      method,
      headers,
      body: body !== undefined ? JSON.stringify(body) : undefined,
    });

    let data = null;
    const text = await res.text();
    if (text) {
      try { data = JSON.parse(text); } catch (e) { /* non-JSON response */ }
    }

    if (!res.ok) {
      const message = (data && data.error) || res.statusText || "Request failed";
      const err = new Error(message);
      err.status = res.status;
      err.data = data;
      throw err;
    }
    return data;
  },

  get(path) { return this.request("GET", path); },
  post(path, body) { return this.request("POST", path, body); },
  patch(path, body) { return this.request("PATCH", path, body); },
  put(path, body) { return this.request("PUT", path, body); },
  del(path) { return this.request("DELETE", path); },

  // Tokenize hits the mock processor endpoint directly, never our
  // authenticated API — matching how a real hosted card field talks
  // straight to the processor's own servers.
  async tokenizeCard(cardDetails) {
    const res = await fetch("/processor/tokenize", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(cardDetails),
    });
    const data = await res.json().catch(() => null);
    if (!res.ok) {
      const err = new Error((data && data.error) || "Card could not be validated");
      throw err;
    }
    return data;
  },
};

function requireAuth() {
  if (!API.isLoggedIn()) {
    window.location.href = "/login.html";
  }
}

function logout() {
  API.setToken(null);
  window.location.href = "/login.html";
}

function formatMoney(cents, currency) {
  return (cents / 100).toLocaleString(undefined, { style: "currency", currency: currency || "USD" });
}

function formatDate(iso) {
  return new Date(iso).toLocaleString();
}

function escapeHtml(str) {
  const div = document.createElement("div");
  div.textContent = str ?? "";
  return div.innerHTML;
}

