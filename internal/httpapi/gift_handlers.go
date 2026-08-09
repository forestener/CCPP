package httpapi

import (
	"errors"
	"net/http"

	"giftpay/internal/store"
)

func (api *API) handleListGifts(w http.ResponseWriter, r *http.Request) {
	gifts, err := api.Store.ListActiveGifts()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load gifts")
		return
	}
	writeJSON(w, http.StatusOK, gifts)
}

func (api *API) handleGetGift(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")

	gift, err := api.Store.GetGiftByID(id)
	if errors.Is(err, store.ErrNotFound) {
		writeError(w, http.StatusNotFound, "gift not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not load gift")
		return
	}
	if !gift.Active {
		writeError(w, http.StatusNotFound, "gift not found")
		return
	}

	writeJSON(w, http.StatusOK, gift)
}
