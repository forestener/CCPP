requireAuth();

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

async function init() {
  try {
    const me = await API.get("/api/me");
    if (!me.is_admin) {
      window.location.href = "/dashboard.html";
      return;
    }
  } catch (err) {
    if (err.status === 401) return logout();
  }

  loadGifts();
  loadOrders();
  loadUsers();
}

// ---- Gifts ----
let editingGiftId = null;

async function loadGifts() {
  const tbody = document.querySelector("#giftsTable tbody");
  try {
    const gifts = await API.get("/api/admin/gifts");
    if (gifts.length === 0) {
      tbody.innerHTML = `<tr><td colspan="4" class="muted">No gifts yet.</td></tr>`;
      return;
    }
    tbody.innerHTML = gifts
      .map(
        (g) => `
      <tr>
        <td>${escapeHtml(g.name)}</td>
        <td>${formatMoney(g.price_cents, g.currency)}</td>
        <td>${g.active ? "Yes" : "No"}</td>
        <td>
          <button class="secondary small" data-edit="${g.id}">Edit</button>
          <button class="danger small" data-delete="${g.id}">Delete</button>
        </td>
      </tr>`
      )
      .join("");

    tbody.querySelectorAll("[data-edit]").forEach((btn) =>
      btn.addEventListener("click", () => {
        const gift = gifts.find((g) => g.id === btn.dataset.edit);
        startEditGift(gift);
      })
    );
    tbody.querySelectorAll("[data-delete]").forEach((btn) =>
      btn.addEventListener("click", async () => {
        if (!confirm("Delete this gift? This only works if it has no orders yet.")) return;
        try {
          await API.del(`/api/admin/gifts/${btn.dataset.delete}`);
          loadGifts();
        } catch (err) {
          showGlobalMsg(err.message, "error");
        }
      })
    );
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="4" class="muted">Could not load gifts.</td></tr>`;
  }
}

function startEditGift(gift) {
  editingGiftId = gift.id;
  document.getElementById("giftFormTitle").textContent = `Edit "${gift.name}"`;
  document.getElementById("giftName").value = gift.name;
  document.getElementById("giftDescription").value = gift.description;
  document.getElementById("giftPrice").value = (gift.price_cents / 100).toFixed(2);
  document.getElementById("giftImage").value = gift.image_url;
  document.getElementById("giftActive").checked = gift.active;
  document.getElementById("giftSubmitBtn").textContent = "Save changes";
  document.getElementById("giftCancelBtn").classList.remove("hidden");
  window.scrollTo({ top: 0, behavior: "smooth" });
}

function resetGiftForm() {
  editingGiftId = null;
  document.getElementById("giftForm").reset();
  document.getElementById("giftActive").checked = true;
  document.getElementById("giftFormTitle").textContent = "Add a gift";
  document.getElementById("giftSubmitBtn").textContent = "Add gift";
  document.getElementById("giftCancelBtn").classList.add("hidden");
}

document.getElementById("giftCancelBtn").addEventListener("click", resetGiftForm);

document.getElementById("giftForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const payload = {
    name: document.getElementById("giftName").value,
    description: document.getElementById("giftDescription").value,
    price_cents: Math.round(Number(document.getElementById("giftPrice").value) * 100),
    currency: "USD",
    image_url: document.getElementById("giftImage").value,
    active: document.getElementById("giftActive").checked,
  };

  try {
    if (editingGiftId) {
      await API.put(`/api/admin/gifts/${editingGiftId}`, payload);
      showGlobalMsg("Gift updated.", "success");
    } else {
      await API.post("/api/admin/gifts", payload);
      showGlobalMsg("Gift added.", "success");
    }
    resetGiftForm();
    loadGifts();
  } catch (err) {
    showGlobalMsg(err.message, "error");
  }
});

// ---- Orders ----
async function loadOrders() {
  const tbody = document.querySelector("#ordersTable tbody");
  try {
    const [orders, users] = await Promise.all([API.get("/api/admin/orders"), API.get("/api/admin/users")]);
    const userEmails = {};
    users.forEach((u) => (userEmails[u.id] = u.email));

    if (orders.length === 0) {
      tbody.innerHTML = `<tr><td colspan="5" class="muted">No orders yet.</td></tr>`;
      return;
    }
    tbody.innerHTML = orders
      .map(
        (o) => `
      <tr>
        <td>${formatDate(o.created_at)}</td>
        <td>${escapeHtml(userEmails[o.user_id] || o.user_id)}</td>
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

// ---- Users ----
async function loadUsers() {
  const tbody = document.querySelector("#usersTable tbody");
  try {
    const users = await API.get("/api/admin/users");
    tbody.innerHTML = users
      .map(
        (u) => `
      <tr>
        <td>${escapeHtml(u.name)}</td>
        <td>${escapeHtml(u.email)}</td>
        <td>${escapeHtml(u.phone || "")}</td>
        <td>${u.is_admin ? "Yes" : "No"}</td>
      </tr>`
      )
      .join("");
  } catch (err) {
    tbody.innerHTML = `<tr><td colspan="4" class="muted">Could not load customers.</td></tr>`;
  }
}

init();

