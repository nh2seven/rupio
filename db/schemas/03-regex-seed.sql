-- Seed regex patterns for HDFC, Union Bank, and GPay/Google Pay email formats.
-- These are starting points — tune the patterns against your actual emails.
-- Run after schema.sql: docker exec -i postgres psql -U finance -d finance < regex-seed.sql

-- ── HDFC debit via UPI (Outlook) ──────────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'hdfc_debit_upi',
  'outlook',
  'alerts@hdfcbank.net',
  'Rs\.(?P<amount>[\d,]+\.?\d*) debited from .*?UPI[:/](?P<utr>\d+).*?(?:to|at)\s+(?P<merchant>[^\.\n]+)',
  '{"amount": "amount", "utr": "utr", "merchant": "merchant", "direction": "debit", "account": "hdfc"}',
  5
);

-- ── HDFC credit (Outlook) ─────────────────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'hdfc_credit_upi',
  'outlook',
  'alerts@hdfcbank.net',
  'Rs\.(?P<amount>[\d,]+\.?\d*) credited to .*?UPI[:/](?P<utr>\d+).*?(?:from|by)\s+(?P<merchant>[^\.\n]+)',
  '{"amount": "amount", "utr": "utr", "merchant": "merchant", "direction": "credit", "account": "hdfc"}',
  5
);

-- ── HDFC debit card purchase (Outlook) ────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'hdfc_debit_card',
  'outlook',
  'alerts@hdfcbank.net',
  'Rs\.(?P<amount>[\d,]+\.?\d*).*?(?:spent|used).*?at\s+(?P<merchant>[^\.\n]+?)(?:\s+on\s+(?P<date>\d{2}[/-]\d{2}[/-]\d{2,4}))?',
  '{"amount": "amount", "merchant": "merchant", "direction": "debit", "account": "hdfc"}',
  8
);

-- ── Union Bank debit (Outlook) ────────────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'union_bank_debit',
  'outlook',
  'unionbank',
  'INR\s*(?P<amount>[\d,]+\.?\d*).*?(?:debited|withdrawn).*?(?:Ref(?:erence)?(?:\s*No\.?)?\s*:?\s*(?P<utr>\d+))?.*?(?:to|at|towards)\s+(?P<merchant>[^\.\n]+)',
  '{"amount": "amount", "utr": "utr", "merchant": "merchant", "direction": "debit", "account": "union"}',
  5
);

-- ── Google Pay payment confirmation (Gmail) ───────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'gpay_payment',
  'gmail',
  'noreply@google.com',
  '(?:You paid|Payment of)\s+(?:₹|Rs\.?|INR)\s*(?P<amount>[\d,]+\.?\d*)\s+(?:to\s+)?(?P<merchant>[^\n]+?)(?:\s+(?:UPI Ref|Transaction ID|Ref)[\s:]+(?P<utr>\w+))?',
  '{"amount": "amount", "merchant": "merchant", "utr": "utr", "direction": "debit", "account": "gpay"}',
  5
);

-- ── Google Play Store receipt (Gmail) ─────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'google_play_receipt',
  'gmail',
  'noreply@google.com',
  '(?:Order total|Amount charged)[:\s]+(?:₹|Rs\.?|INR)\s*(?P<amount>[\d,]+\.?\d*).*?(?:Order ID[:\s]+(?P<utr>GPA\.[^\s]+))?',
  '{"amount": "amount", "utr": "utr", "direction": "debit", "account": "gpay", "merchant": "Google Play"}',
  5
);

-- ── Steam purchase (Gmail) ────────────────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'steam_purchase',
  'gmail',
  'noreply@steampowered.com',
  'Total[:\s]+(?:₹|Rs\.?|INR|\$)\s*(?P<amount>[\d,]+\.?\d*).*?(?:Transaction ID[:\s]+(?P<utr>\d+))?',
  '{"amount": "amount", "utr": "utr", "direction": "debit", "account": "gpay", "merchant": "Steam"}',
  5
);

-- ── Swiggy order receipt (Gmail) ──────────────────────────────────────────────
INSERT INTO regex_patterns (name, source, sender, pattern, fields, priority) VALUES (
  'swiggy_receipt',
  'gmail',
  'noreply@swiggy.in',
  '(?:Order Total|Total Amount|Amount Paid)[:\s]+(?:₹|Rs\.?)\s*(?P<amount>[\d,]+\.?\d*).*?(?:Order ID[:\s]+#?(?P<utr>\w+))?',
  '{"amount": "amount", "utr": "utr", "direction": "debit", "account": "gpay", "merchant": "Swiggy"}',
  5
);
