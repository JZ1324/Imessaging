const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("reveal");
      }
    });
  },
  { threshold: 0.15 }
);

document.querySelectorAll(".card, .privacy-card, .cta-card, .pricing-card, .hero-card").forEach((el) => {
  el.classList.add("fade-in");
  observer.observe(el);
});
