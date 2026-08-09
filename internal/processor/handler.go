package processor

import (
	"encoding/json"
	"net/http"
)

// TokenizeHandler simulates the endpoint a processor's own hosted
// field/SDK would post to on *their* servers. It is deliberately not
// protected by this app's session auth (a real processor doesn't require
// your app's login to accept a card) — the boundary that matters is that
// this handler, and only this handler, ever sees a raw card number or CVV,
// and it never writes them to a log or a database. Only the resulting
// token + masked metadata cross back into the rest of the application.
func TokenizeHandler(p *Processor) http.HandlerFunc {
	type request struct {
		CardNumber     string `json:"card_number"`
		CVV            string `json:"cvv"`
		ExpMonth       int    `json:"exp_month"`
		ExpYear        int    `json:"exp_year"`
		CardholderName string `json:"cardholder_name"`
	}
	type response struct {
		Token    string `json:"token"`
		Brand    string `json:"brand"`
		Last4    string `json:"last4"`
		ExpMonth int    `json:"exp_month"`
		ExpYear  int    `json:"exp_year"`
	}

	return func(w http.ResponseWriter, r *http.Request) {
		var req request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeJSONError(w, http.StatusBadRequest, "invalid request body")
			return
		}

		result, err := p.Tokenize(TokenizeRequest{
			CardNumber:     req.CardNumber,
			CVV:            req.CVV,
			ExpMonth:       req.ExpMonth,
			ExpYear:        req.ExpYear,
			CardholderName: req.CardholderName,
		})
		if err != nil {
			// err's message is a validation reason only (e.g. "card number
			// fails checksum validation") — it never includes the raw card
			// number/CVV, so it's safe to return to the client.
			writeJSONError(w, http.StatusUnprocessableEntity, err.Error())
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		json.NewEncoder(w).Encode(response{
			Token:    result.Token,
			Brand:    result.Brand,
			Last4:    result.Last4,
			ExpMonth: result.ExpMonth,
			ExpYear:  result.ExpYear,
		})
	}
}

func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}
