// Web Analyzer
let db = null;
let charts = {};

if (typeof Chart !== "undefined") {
  Chart.defaults.animation = false;
  if (Chart.defaults.transitions && Chart.defaults.transitions.active) {
    Chart.defaults.transitions.active.animation.duration = 0;
  }
}

// Custom smooth scrolling with max speed
const MAX_SCROLL_STEP = 200;
const SCROLL_EASE = 0.28;
const SCROLL_SCALE = 1.3;
const scrollContainer = document.querySelector('main');
let scrollTarget = scrollContainer ? scrollContainer.scrollTop : window.scrollY;
let scrollAnimating = false;

function clampScrollTarget(value) {
  if (!scrollContainer) {
    const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
    return Math.max(0, Math.min(maxScroll, value));
  }
  const maxScroll = scrollContainer.scrollHeight - scrollContainer.clientHeight;
  return Math.max(0, Math.min(maxScroll, value));
}

function getScrollTop() {
  return scrollContainer ? scrollContainer.scrollTop : window.scrollY;
}

function setScrollTop(value) {
  if (scrollContainer) {
    scrollContainer.scrollTop = value;
  } else {
    window.scrollTo(0, value);
  }
}

function animateScroll() {
  const current = getScrollTop();
  const delta = scrollTarget - current;
  if (Math.abs(delta) < 0.5) {
    setScrollTop(scrollTarget);
    scrollAnimating = false;
    return;
  }
  setScrollTop(current + delta * SCROLL_EASE);
  requestAnimationFrame(animateScroll);
}

const wheelHandler = (event) => {
  if (event.ctrlKey) return;
  event.preventDefault();
  const scaled = event.deltaY * SCROLL_SCALE;
  const capped = Math.max(-MAX_SCROLL_STEP, Math.min(MAX_SCROLL_STEP, scaled));
  scrollTarget = clampScrollTarget(getScrollTop() + capped);
  if (!scrollAnimating) {
    scrollAnimating = true;
    requestAnimationFrame(animateScroll);
  }
};

(scrollContainer || window).addEventListener('wheel', wheelHandler, { passive: false });
window.addEventListener('wheel', wheelHandler, { passive: false });

// Keep target in sync if user scrolls via keyboard or scrollbar
const scrollRoot = scrollContainer || window;
scrollRoot.addEventListener('scroll', () => {
  if (!scrollAnimating) {
    scrollTarget = getScrollTop();
  }
});

window.addEventListener('resize', () => {
  scrollTarget = clampScrollTarget(scrollTarget);
});

function getTargetOffset(target) {
  if (!scrollContainer) return target.getBoundingClientRect().top + window.scrollY;
  const containerRect = scrollContainer.getBoundingClientRect();
  const targetRect = target.getBoundingClientRect();
  return scrollContainer.scrollTop + (targetRect.top - containerRect.top);
}

function smoothScrollTo(target) {
  scrollTarget = clampScrollTarget(target);
  if (!scrollAnimating) {
    scrollAnimating = true;
    requestAnimationFrame(animateScroll);
  }
}

document.querySelectorAll('a[href^="#"]').forEach(anchor => {
  anchor.addEventListener('click', (event) => {
    const href = anchor.getAttribute('href');
    if (!href || href === '#') return;
    const target = document.querySelector(href);
    if (!target) return;
    event.preventDefault();
    smoothScrollTo(getTargetOffset(target));
  });
});

// Navigation
document.getElementById('tryAnalyzer')?.addEventListener('click', () => {
  document.querySelector('.hero').style.display = 'none';
  document.querySelectorAll('section:not(.hero)').forEach(s => s.style.display = 'none');
  document.querySelector('.nav').style.display = 'none';
  document.querySelector('.footer').style.display = 'none';
  document.getElementById('analyzer').style.display = 'block';
});

document.getElementById('backToHome')?.addEventListener('click', () => {
  document.getElementById('analyzer').style.display = 'none';
  document.querySelector('.hero').style.display = 'block';
  document.querySelectorAll('section:not(.hero)').forEach(s => s.style.display = 'block');
  document.querySelector('.nav').style.display = 'flex';
  document.querySelector('.footer').style.display = 'flex';
});

// Tab navigation
document.querySelectorAll('.stat-tab').forEach(tab => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.stat-tab').forEach(t => t.classList.remove('active'));
    document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
    tab.classList.add('active');
    const tabId = tab.dataset.tab + 'Tab';
    document.getElementById(tabId).classList.add('active');
  });
});

// Hero preview tabs
document.querySelectorAll('.screen-tabs .pill').forEach(button => {
  button.addEventListener('click', () => {
    const panel = button.dataset.panel;
    if (!panel) return;
    document.querySelectorAll('.screen-tabs .pill').forEach(p => p.classList.remove('active'));
    document.querySelectorAll('.screen-panel').forEach(p => p.classList.remove('active'));
    button.classList.add('active');
    document.querySelector(`.screen-panel[data-panel="${panel}"]`)?.classList.add('active');
  });
});

// Subtle scroll reveal
const revealTargets = document.querySelectorAll(
  'section, .hero, .feature-grid .card, .privacy-card, .cta-card, .pricing-card'
);

const revealObserver = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add('is-visible');
      } else {
        entry.target.classList.remove('is-visible');
      }
    });
  },
  {
    threshold: 0.2,
    rootMargin: '0px 0px -40px 0px',
    root: scrollContainer || null
  }
);

revealTargets.forEach((el) => {
  el.classList.add('scroll-reveal');
  revealObserver.observe(el);
});

// File upload handler
document.getElementById('dbFile')?.addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  
  document.getElementById('uploadSection').style.display = 'none';
  document.getElementById('loadingSection').style.display = 'block';
  
  try {
    await loadDatabase(file);
    await analyzeDatabase();
    document.getElementById('loadingSection').style.display = 'none';
    document.getElementById('statsSection').style.display = 'block';
  } catch (error) {
    console.error('Error processing database:', error);
    document.getElementById('loadingText').textContent = 'Error: ' + error.message;
  }
});

async function loadDatabase(file) {
  document.getElementById('loadingText').textContent = 'Loading database...';
  
  const SQL = await initSqlJs({
    locateFile: file => `https://cdnjs.cloudflare.com/ajax/libs/sql.js/1.8.0/${file}`
  });
  
  const arrayBuffer = await file.arrayBuffer();
  const uint8Array = new Uint8Array(arrayBuffer);
  db = new SQL.Database(uint8Array);
}

async function analyzeDatabase() {
  if (!db) return;
  
  document.getElementById('loadingText').textContent = 'Analyzing messages...';
  
  // Get total messages
  const totalResult = db.exec(`
    SELECT COUNT(*) as count,
           SUM(CASE WHEN is_from_me = 1 THEN 1 ELSE 0 END) as sent,
           SUM(CASE WHEN is_from_me = 0 THEN 1 ELSE 0 END) as received
    FROM message
  `);
  
  if (totalResult.length > 0) {
    const [count, sent, received] = totalResult[0].values[0];
    document.getElementById('totalMessages').textContent = count.toLocaleString();
    document.getElementById('sentMessages').textContent = sent.toLocaleString();
    document.getElementById('receivedMessages').textContent = received.toLocaleString();
  }
  
  // Get total chats
  const chatsResult = db.exec('SELECT COUNT(*) as count FROM chat');
  if (chatsResult.length > 0) {
    document.getElementById('totalChats').textContent = chatsResult[0].values[0][0].toLocaleString();
  }
  
  // Get attachments count
  const attachmentsResult = db.exec('SELECT COUNT(*) as count FROM attachment');
  if (attachmentsResult.length > 0) {
    document.getElementById('totalAttachments').textContent = attachmentsResult[0].values[0][0].toLocaleString();
  }
  
  // Calculate average message length
  const lengthResult = db.exec(`
    SELECT AVG(LENGTH(text)) as avg_length 
    FROM message 
    WHERE text IS NOT NULL AND text != ''
  `);
  if (lengthResult.length > 0) {
    const avgLength = Math.round(lengthResult[0].values[0][0] || 0);
    document.getElementById('avgLength').textContent = avgLength.toLocaleString();
  }
  
  // Activity over time
  createActivityChart();
  
  // Weekday analysis
  createWeekdayChart();
  
  // Hour of day analysis
  createHourChart();
  
  // Top contacts
  displayTopContacts();
  
  // Emoji analysis
  analyzeEmojis();
}

function createActivityChart() {
  const result = db.exec(`
    SELECT date(datetime(date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch'), 'localtime') as day,
           COUNT(*) as count
    FROM message
    WHERE date IS NOT NULL
    GROUP BY day
    ORDER BY day
    LIMIT 365
  `);
  
  if (result.length === 0) return;
  
  const labels = [];
  const data = [];
  
  result[0].values.forEach(row => {
    labels.push(row[0]);
    data.push(row[1]);
  });
  
  const ctx = document.getElementById('activityChart');
  if (charts.activity) charts.activity.destroy();
  
  charts.activity = new Chart(ctx, {
    type: 'line',
    data: {
      labels: labels,
      datasets: [{
        label: 'Messages',
        data: data,
        borderColor: '#6366f1',
        backgroundColor: 'rgba(99, 102, 241, 0.1)',
        tension: 0.4,
        fill: true
      }]
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: false }
      },
      scales: {
        x: { 
          display: true,
          ticks: { maxTicksLimit: 10 }
        },
        y: { 
          beginAtZero: true 
        }
      }
    }
  });
}

function createWeekdayChart() {
  const result = db.exec(`
    SELECT 
      CAST(strftime('%w', datetime(date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch'), 'localtime') AS INTEGER) as weekday,
      COUNT(*) as count
    FROM message
    WHERE date IS NOT NULL
    GROUP BY weekday
    ORDER BY weekday
  `);
  
  if (result.length === 0) return;
  
  const weekdays = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const data = new Array(7).fill(0);
  
  result[0].values.forEach(row => {
    data[row[0]] = row[1];
  });
  
  const ctx = document.getElementById('weekdayChart');
  if (charts.weekday) charts.weekday.destroy();
  
  charts.weekday = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: weekdays,
      datasets: [{
        label: 'Messages',
        data: data,
        backgroundColor: '#8b5cf6'
      }]
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: false }
      },
      scales: {
        y: { beginAtZero: true }
      }
    }
  });
}

function createHourChart() {
  const result = db.exec(`
    SELECT 
      CAST(strftime('%H', datetime(date/1000000000 + strftime('%s', '2001-01-01'), 'unixepoch'), 'localtime') AS INTEGER) as hour,
      COUNT(*) as count
    FROM message
    WHERE date IS NOT NULL
    GROUP BY hour
    ORDER BY hour
  `);
  
  if (result.length === 0) return;
  
  const data = new Array(24).fill(0);
  
  result[0].values.forEach(row => {
    data[row[0]] = row[1];
  });
  
  const labels = Array.from({length: 24}, (_, i) => {
    const hour = i % 12 || 12;
    const ampm = i < 12 ? 'AM' : 'PM';
    return `${hour}${ampm}`;
  });
  
  const ctx = document.getElementById('hourChart');
  if (charts.hour) charts.hour.destroy();
  
  charts.hour = new Chart(ctx, {
    type: 'bar',
    data: {
      labels: labels,
      datasets: [{
        label: 'Messages',
        data: data,
        backgroundColor: '#ec4899'
      }]
    },
    options: {
      responsive: true,
      plugins: {
        legend: { display: false }
      },
      scales: {
        y: { beginAtZero: true }
      }
    }
  });
}

function displayTopContacts() {
  const result = db.exec(`
    SELECT 
      COALESCE(h.id, 'Unknown') as contact,
      COUNT(*) as count
    FROM message m
    LEFT JOIN handle h ON m.handle_id = h.ROWID
    WHERE m.is_from_me = 0
    GROUP BY contact
    ORDER BY count DESC
    LIMIT 10
  `);
  
  if (result.length === 0) return;
  
  const container = document.getElementById('topContactsList');
  container.innerHTML = '';
  
  result[0].values.forEach((row, index) => {
    const contact = row[0];
    const count = row[1];
    
    const item = document.createElement('div');
    item.className = 'contact-item';
    item.innerHTML = `
      <div class=\"contact-rank\">${index + 1}</div>
      <div class=\"contact-info\">
        <div class=\"contact-name\">${contact}</div>
        <div class=\"contact-count\">${count.toLocaleString()} messages</div>
      </div>
    `;
    container.appendChild(item);
  });
}

function analyzeEmojis() {
  const result = db.exec(`
    SELECT text FROM message WHERE text IS NOT NULL AND text != ''
  `);
  
  if (result.length === 0) return;
  
  const emojiRegex = /[\u{1F600}-\u{1F64F}\u{1F300}-\u{1F5FF}\u{1F680}-\u{1F6FF}\u{1F1E0}-\u{1F1FF}\u{2600}-\u{26FF}\u{2700}-\u{27BF}]/gu;
  const emojiCounts = {};
  
  result[0].values.forEach(row => {
    const text = row[0];
    if (!text) return;
    
    const matches = text.match(emojiRegex);
    if (matches) {
      matches.forEach(emoji => {
        emojiCounts[emoji] = (emojiCounts[emoji] || 0) + 1;
      });
    }
  });
  
  const sorted = Object.entries(emojiCounts)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 20);
  
  const container = document.getElementById('emojiList');
  container.innerHTML = '';
  
  sorted.forEach(([emoji, count]) => {
    const item = document.createElement('div');
    item.className = 'emoji-item';
    item.innerHTML = `
      <span class=\"emoji\">${emoji}</span>
      <span class=\"emoji-count\">${count.toLocaleString()}</span>
    `;
    container.appendChild(item);
  });
}
