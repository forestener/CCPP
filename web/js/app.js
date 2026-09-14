requireAuth();

let currentUser = null;
let selectedGift = null;
let profilePhotoObjectUrl = null;

// Keep the expiry-year bounds tied to today's date instead of a hardcoded
// value that would silently go stale (and reject valid future years, or
// wrongly accept already-expired ones).
(() => {
  const currentYear = new Date().getFullYear();
  const yearInput = document.getElementById("expYear");
  yearInput.min = currentYear;
  yearInput.max = currentYear + 30;
})();

// ---- Tabs ----
document.querySelectorAll(".tab-btn").forEach((btn) => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach((b) => b.classList.remove("active"));
    document.querySelectorAll(".panel").forEach((p) => p.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("panel-" + btn.dataset.tab).classList.add("active");
  });
});

document.getElementById("logoutLink").addEventListener("click", (e) => {
  e.preventDefault();
  API.post("/api/auth/logout").catch(() => {}).finally(logout);
});

function showGlobalMsg(text, type) {
  const el = document.getElementById("globalMsg");
  el.innerHTML = `<div class="msg ${type}">${escapeHtml(text)}</div>`;
  setTimeout(() => (el.innerHTML = ""), 4000);
}

// ---- Bootstrap ----
async function init() {
  try {
    currentUser = await API.get("/api/me");
  } catch (err) {
    if (err.status === 401) return logout();
    showGlobalMsg(err.message, "error");
    return;
  }

  document.getElementById("welcomeText").textContent = `Hi, ${currentUser.name}`;
  if (currentUser.is_admin) document.getElementById("adminLink").classList.remove("hidden");

  document.getElementById("profileEmail").value = currentUser.email;
  document.getElementById("profileName").value = currentUser.name;
  document.getElementById("profilePhone").value = currentUser.phone || "";
  loadProfilePhoto();

  loadGifts();
  loadCards();
  loadOrders();
}

// ---- Gifts ----
async function loadGifts() {
  const grid = document.getElementById("giftsGrid");
  try {
    const gifts = await API.get("/api/gifts");
    if (gifts.length === 0) {
      grid.innerHTML = `<p class="muted">No gifts available right now.</p>`;
      return;
    }
    grid.innerHTML = gifts
      .map(
        (g) => `
      <div class="card gift-card">
        <img src="${escapeHtml(g.image_url)}" alt="${escapeHtml(g.name)}" onerror="this.style.display='none'" />
        <h3>${escapeHtml(g.name)}</h3>
        <p class="muted">${escapeHtml(g.description)}</p>
        <p class="gift-price">${formatMoney(g.price_cents, g.currency)}</p>
        <button data-gift-id="${g.id}" class="buy-btn" style="width:100%;">Buy</button>
      </div>`
      )
      .join("");

    grid.querySelectorAll(".buy-btn").forEach((btn) => {
      btn.addEventListener("click", () => openCheckout(gifts.find((g) => g.id === btn.dataset.giftId)));
    });
  } catch (err) {
    grid.innerHTML = `<p class="muted">Could not load gifts.</p>`;
  }
}

// ---- Payment methods ----
async function loadCards() {
  const list = document.getElementById("cardsList");
  try {
    const cards = await API.get("/api/payment-methods");
    if (cards.length === 0) {
      list.innerHTML = `<p class="muted">No saved cards yet.</p>`;
      return;
    }
    list.innerHTML = cards
      .map(
        (c) => `
      <div class="card-item">
        <div>
          <strong>${escapeHtml(c.brand)} ending in ${escapeHtml(c.last4)}</strong>
          <span class="muted"> &middot; exp ${String(c.exp_month).padStart(2, "0")}/${c.exp_year}</span>
          ${c.is_default ? '<span class="pill default">Default</span>' : ""}
        </div>
        <div class="row" style="flex:none; gap:8px;">
          ${!c.is_default ? `<button class="secondary small" data-default-id="${c.id}">Make default</button>` : ""}
          <button class="danger small" data-delete-id="${c.id}">Delete</button>
        </div>
      </div>`
      )
      .join("");

    list.querySelectorAll("[data-default-id]").forEach((btn) =>
      btn.addEventListener("click", async () => {
        try {
          await API.post(`/api/payment-methods/${btn.dataset.defaultId}/default`);
          loadCards();
        } catch (err) {
          showGlobalMsg(err.message, "error");
        }
      })
    );
    list.querySelectorAll("[data-delete-id]").forEach((btn) =>
      btn.addEventListener("click", async () => {
        if (!confirm("Delete this saved card?")) return;
        try {
          await API.del(`/api/payment-methods/${btn.dataset.deleteId}`);
          loadCards();
        } catch (err) {
          showGlobalMsg(err.message, "error");
        }
      })
    );
  } catch (err) {
    list.innerHTML = `<p class="muted">Could not load cards.</p>`;
  }
}

document.getElementById("addCardForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const submitBtn = e.target.querySelector("button[type=submit]");
  submitBtn.disabled = true;
  try {
    const tokenized = await API.tokenizeCard({
      card_number: document.getElementById("cardNumber").value.replace(/\s+/g, ""),
      cvv: document.getElementById("cvv").value,
      exp_month: Number(document.getElementById("expMonth").value),
      exp_year: Number(document.getElementById("expYear").value),
      cardholder_name: document.getElementById("cardholderName").value,
    });

    await API.post("/api/payment-methods", {
      token: tokenized.token,
      brand: tokenized.brand,
      last4: tokenized.last4,
      exp_month: tokenized.exp_month,
      exp_year: tokenized.exp_year,
      cardholder_name: document.getElementById("cardholderName").value,
      make_default: document.getElementById("makeDefault").checked,
    });

    e.target.reset();
    showGlobalMsg("Card saved.", "success");
    loadCards();
  } catch (err) {
    showGlobalMsg(err.message, "error");
  } finally {
    submitBtn.disabled = false;
  }
});

// ---- Checkout ----
async function openCheckout(gift) {
  selectedGift = gift;
  document.getElementById("checkoutGiftLabel").textContent = `${gift.name} — ${formatMoney(gift.price_cents, gift.currency)}`;
  document.getElementById("checkoutMsg").innerHTML = "";

  const optionsEl = document.getElementById("checkoutCardOptions");
  optionsEl.innerHTML = `<p class="muted">Loading your cards...</p>`;
  document.getElementById("checkoutModal").classList.remove("hidden");

  try {
    const cards = await API.get("/api/payment-methods");
    if (cards.length === 0) {
      optionsEl.innerHTML = `<p class="muted">You have no saved cards. Add one from the Payment Methods tab first.</p>`;
      return;
    }
    optionsEl.innerHTML = cards
      .map(
        (c, i) => `
      <label style="display:flex; align-items:center; gap:8px; font-weight:normal; margin:6px 0;">
        <input type="radio" name="checkoutCard" value="${c.id}" style="width:auto;" ${i === 0 ? "checked" : ""} />
        ${escapeHtml(c.brand)} ending in ${escapeHtml(c.last4)} ${c.is_default ? "(default)" : ""}
      </label>`
      )
      .join("");
  } catch (err) {
    optionsEl.innerHTML = `<p class="muted">Could not load your cards.</p>`;
  }
}

document.getElementById("checkoutCancel").addEventListener("click", () => {
  document.getElementById("checkoutModal").classList.add("hidden");
});

document.getElementById("checkoutConfirm").addEventListener("click", async () => {
  const selected = document.querySelector('input[name="checkoutCard"]:checked');
  const msgEl = document.getElementById("checkoutMsg");
  if (!selected) {
    msgEl.innerHTML = `<div class="msg error">Choose a card first.</div>`;
    return;
  }

  const confirmBtn = document.getElementById("checkoutConfirm");
  confirmBtn.disabled = true;
  try {
    const order = await API.post("/api/orders", {
      gift_id: selectedGift.id,
      payment_method_id: selected.value,
    });
    if (order.status === "succeeded") {
      msgEl.innerHTML = `<div class="msg success">Payment succeeded! Check Order History for details.</div>`;
    } else {
      msgEl.innerHTML = `<div class="msg error">Payment failed (${escapeHtml(order.failure_reason || "declined")}).</div>`;
    }
    loadOrders();
    setTimeout(() => document.getElementById("checkoutModal").classList.add("hidden"), 1500);
  } catch (err) {
    msgEl.innerHTML = `<div class="msg error">${escapeHtml(err.message)}</div>`;
  } finally {
    confirmBtn.disabled = false;
  }
});

// ---- Orders ----
async function loadOrders() {
  const tbody = document.querySelector("#ordersTable tbody");
  try {
    const orders = await API.get("/api/orders");
    if (orders.length === 0) {
      tbody.innerHTML = `<tr><td colspan="5" class="muted">No orders yet.</td></tr>`;
      return;
    }
    const giftNames = {};
    try {
      (await API.get("/api/gifts")).forEach((g) => (giftNames[g.id] = g.name));
    } catch (e) { /* best effort */ }

    tbody.innerHTML = orders
      .map(
        (o) => `
      <tr>
        <td>${formatDate(o.created_at)}</td>
        <td>${escapeHtml(giftNames[o.gift_id] || o.gift_id)}</td>
        <td>${formatMoney(o.amount_cents, o.currency)}</td>
        <td>${escapeHtml(o.masked_card)}</td>
        <td><span class="pill ${o.status === "succeeded" ? "succeeded" : "failed"}">${escapeHtml(o.status)}</span></td>
      </tr>`
      )
      .join("");
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="5" class="muted">Could not load orders.</td></tr>`;
  }
}

// ---- Profile ----
document.getElementById("profileForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  try {
    currentUser = await API.patch("/api/me", {
      name: document.getElementById("profileName").value,
      phone: document.getElementById("profilePhone").value,
    });
    document.getElementById("welcomeText").textContent = `Hi, ${currentUser.name}`;
    showGlobalMsg("Profile updated.", "success");
  } catch (err) {
    showGlobalMsg(err.message, "error");
  }
});

async function loadProfilePhoto() {
  const preview = document.getElementById("profilePhotoPreview");
  const placeholder = document.getElementById("profilePhotoPlaceholder");

  if (profilePhotoObjectUrl) {
    URL.revokeObjectURL(profilePhotoObjectUrl);
    profilePhotoObjectUrl = null;
  }

  if (!currentUser || !currentUser.profile_photo_url) {
    preview.classList.add("hidden");
    preview.removeAttribute("src");
    placeholder.classList.remove("hidden");
    return;
  }

  try {
    const blob = await API.getBlob(currentUser.profile_photo_url);
    profilePhotoObjectUrl = URL.createObjectURL(blob);
    preview.src = profilePhotoObjectUrl;
    preview.classList.remove("hidden");
    placeholder.classList.add("hidden");
  } catch (err) {
    preview.classList.add("hidden");
    preview.removeAttribute("src");
    placeholder.classList.remove("hidden");
  }
}

document.getElementById("profilePhotoForm").addEventListener("submit", async (e) => {
  e.preventDefault();

  const input = document.getElementById("profilePhoto");
  const submitBtn = e.target.querySelector("button[type=submit]");
  if (!input.files || input.files.length === 0) {
    showGlobalMsg("Choose a photo first.", "error");
    return;
  }

  const formData = new FormData();
  formData.append("photo", input.files[0]);

  submitBtn.disabled = true;
  try {
    currentUser = await API.upload("/api/me/photo", formData);
    await loadProfilePhoto();
    input.value = "";
    showGlobalMsg("Profile photo updated.", "success");
  } catch (err) {
    showGlobalMsg(err.message, "error");
  } finally {
    submitBtn.disabled = false;
  }
});

init();

