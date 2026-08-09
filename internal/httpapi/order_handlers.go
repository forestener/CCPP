package httpapi

import (
	"errors"
	"net/http"

	"giftpay/internal/auth"
	"giftpay/internal/processor"
	"giftpay/internal/store"
)

type createOrderRequest struct {
	GiftID          string `json:"gift_id"`
	PaymentMethodID string `json:"payment_method_id"`
}

func (api *API) handleCreateOrder(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	var req createOrderRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request body")
		return
	}
	if !isNonEmpty(req.GiftID) || !isNonEmpty(req.PaymentMethodID) {
		writeError(w, http.StatusBadRequest, "gift_id and payment_method_id are required")
		return
	}

	gift, err := api.Store.GetGiftByID(req.GiftID)
	if errors.Is(err, store.ErrNotFound) || (err == nil && !gift.Active) {
		writeError(w, http.StatusNotFound, "gift not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load gift")
		return
	}

	pm, err := api.Store.GetPaymentMethodForUser(req.PaymentMethodID, claims.UserID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "payment method not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load payment method")
		return
	}

	// FR-13: the backend calls the processor's charge API using only the
	// stored token. Raw card data was never available here to begin with.
	result, err := api.Processor.Charge(pm.ProcessorToken, gift.PriceCents, gift.Currency)
	if errors.Is(err, processor.ErrUnknownToken) {
		writeError(w, http.StatusUnprocessableEntity, "saved card is no longer valid; please add it again")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, "payment processor error")
		return
	}

	newOrder := store.NewOrder{
		UserID:          claims.UserID,
		GiftID:          gift.ID,
		PaymentMethodID: pm.ID,
		AmountCents:     gift.PriceCents,
		Currency:        gift.Currency,
		Status:          result.Status,
		MaskedCard:      pm.Display(),
	}
	if result.ChargeID != "" {
		newOrder.ProcessorChargeID = &result.ChargeID
	}
	if result.Reason != "" {
		newOrder.FailureReason = &result.Reason
	}

	order, err := api.Store.CreateOrder(newOrder)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not record order")
		return
	}

	status := http.StatusCreated
	if order.Status != "succeeded" {
		status = http.StatusPaymentRequired
	}
	writeJSON(w, status, order)
}

func (api *API) handleListOrders(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())

	orders, err := api.Store.ListOrdersForUser(claims.UserID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load orders")
		return
	}
	writeJSON(w, http.StatusOK, orders)
}

func (api *API) handleGetOrder(w http.ResponseWriter, r *http.Request) {
	claims, _ := auth.ClaimsFromContext(r.Context())
	id := r.PathValue("id")

	order, err := api.Store.GetOrderForUser(id, claims.UserID)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "order not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load order")
		return
	}
	writeJSON(w, http.StatusOK, order)
}
