(() => {
  "use strict";

  const SUPABASE_URL = "https://vfeuwjxlmyqktkodzccw.supabase.co";
  const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZmZXV3anhsbXlxa3Rrb2R6Y2N3Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzAzMTA0MjgsImV4cCI6MjA4NTg4NjQyOH0.1Vrti7B8sZSS45-6qkXMHixxvELng07av1Ng7ArNEMw";
  const ALLOWED_CALLBACK = "imessagestats://auth-callback";

  const query = new URLSearchParams(window.location.search);
  const requestState = query.get("state") || "";
  const callback = query.get("callback") || "";
  const requestIsValid = /^[a-f0-9-]{20,64}$/i.test(requestState) && callback === ALLOWED_CALLBACK;

  const form = document.getElementById("authForm");
  const signInTab = document.getElementById("signInTab");
  const signUpTab = document.getElementById("signUpTab");
  const usernameField = document.getElementById("usernameField");
  const usernameInput = document.getElementById("username");
  const emailInput = document.getElementById("email");
  const passwordInput = document.getElementById("password");
  const passwordHint = document.getElementById("passwordHint");
  const submitButton = document.getElementById("submitButton");
  const submitLabel = document.getElementById("submitLabel");
  const status = document.getElementById("status");
  const returnPanel = document.getElementById("returnPanel");
  const openAppButton = document.getElementById("openAppButton");

  let mode = "signin";
  let pendingCallbackURL = "";

  function showStatus(message, type = "error") {
    status.textContent = message;
    status.classList.add("visible");
    status.classList.toggle("success", type === "success");
  }

  function clearStatus() {
    status.textContent = "";
    status.classList.remove("visible", "success");
  }

  function setMode(nextMode) {
    mode = nextMode;
    const isSignUp = mode === "signup";
    signInTab.classList.toggle("active", !isSignUp);
    signUpTab.classList.toggle("active", isSignUp);
    signInTab.setAttribute("aria-selected", String(!isSignUp));
    signUpTab.setAttribute("aria-selected", String(isSignUp));
    usernameField.classList.toggle("hidden", !isSignUp);
    usernameInput.required = isSignUp;
    passwordInput.autocomplete = isSignUp ? "new-password" : "current-password";
    passwordHint.textContent = isSignUp ? "At least 6 characters" : "Your account password";
    submitLabel.textContent = isSignUp ? "Create account and open app" : "Sign in and open app";
    clearStatus();
  }

  function setBusy(isBusy) {
    submitButton.disabled = isBusy;
    submitLabel.textContent = isBusy
      ? (mode === "signup" ? "Creating account…" : "Signing in…")
      : (mode === "signup" ? "Create account and open app" : "Sign in and open app");
  }

  function readableError(payload, response) {
    if (payload && typeof payload === "object") {
      return payload.msg || payload.message || payload.error_description || payload.error || `Sign in failed (${response.status})`;
    }
    return `Sign in failed (${response.status})`;
  }

  function buildCallbackURL(auth, email, username) {
    const fragment = new URLSearchParams({
      access_token: auth.access_token,
      expires_in: String(auth.expires_in || 3600),
      user_id: (auth.user && auth.user.id) || "",
      email: (auth.user && auth.user.email) || email,
      username: username || (auth.user && auth.user.user_metadata && auth.user.user_metadata.username) || "",
      state: requestState
    });

    if (auth.refresh_token) {
      fragment.set("refresh_token", auth.refresh_token);
    }
    return `${ALLOWED_CALLBACK}#${fragment.toString()}`;
  }

  function returnToApp(callbackURL) {
    pendingCallbackURL = callbackURL;
    form.classList.add("hidden");
    document.querySelector(".mode-switch").classList.add("hidden");
    returnPanel.classList.remove("hidden");
    window.location.replace(callbackURL);
  }

  async function authenticate(email, password, username) {
    const isSignUp = mode === "signup";
    const endpoint = isSignUp
      ? `${SUPABASE_URL}/auth/v1/signup`
      : `${SUPABASE_URL}/auth/v1/token?grant_type=password`;
    const body = { email, password };

    if (isSignUp) {
      body.data = { username };
    }

    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "apikey": SUPABASE_ANON_KEY,
        "Authorization": `Bearer ${SUPABASE_ANON_KEY}`
      },
      body: JSON.stringify(body),
      cache: "no-store",
      credentials: "omit",
      referrerPolicy: "no-referrer"
    });

    let payload = null;
    try {
      payload = await response.json();
    } catch (_) {
      payload = null;
    }

    if (!response.ok) {
      throw new Error(readableError(payload, response));
    }
    return payload;
  }

  signInTab.addEventListener("click", () => setMode("signin"));
  signUpTab.addEventListener("click", () => setMode("signup"));

  openAppButton.addEventListener("click", () => {
    if (pendingCallbackURL) {
      window.location.assign(pendingCallbackURL);
    }
  });

  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    clearStatus();

    if (!requestIsValid) {
      showStatus("Please open this sign-in page from the iMessages Stats Mac app.");
      return;
    }

    const email = emailInput.value.trim().toLowerCase();
    const password = passwordInput.value;
    const username = usernameInput.value.trim();

    if (!email || !emailInput.validity.valid) {
      showStatus("Enter a valid email address.");
      emailInput.focus();
      return;
    }
    if (password.length < 6) {
      showStatus("Your password must be at least 6 characters.");
      passwordInput.focus();
      return;
    }
    if (mode === "signup" && !username) {
      showStatus("Choose a username for your account.");
      usernameInput.focus();
      return;
    }

    setBusy(true);
    try {
      const auth = await authenticate(email, password, username);
      passwordInput.value = "";

      if (!auth || !auth.access_token) {
        if (mode === "signup") {
          setMode("signin");
          emailInput.value = email;
          showStatus("Account created. Check your email to confirm it, then return here and sign in.", "success");
        } else {
          showStatus("The server did not return a session. Please try again.");
        }
        return;
      }

      returnToApp(buildCallbackURL(auth, email, username));
    } catch (error) {
      passwordInput.value = "";
      showStatus(error instanceof Error ? error.message : "Unable to sign in. Please try again.");
      passwordInput.focus();
    } finally {
      setBusy(false);
    }
  });

  if (!requestIsValid) {
    submitButton.disabled = true;
    showStatus("Open this page using Continue in Browser inside the iMessages Stats app.");
  }
})();
