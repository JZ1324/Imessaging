// Intersection Observer for animations with staggered delays
const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("reveal");
      }
    });
  },
  { threshold: 0.15, rootMargin: '0px 0px -50px 0px' }
);

// Add animations to different elements with different classes
document.querySelectorAll(".card").forEach((el, index) => {
  el.classList.add("fade-in");
  el.style.transitionDelay = `${index * 0.08}s`;
  observer.observe(el);
});

document.querySelectorAll(".privacy-card, .cta-card, .pricing-card").forEach((el) => {
  el.classList.add("scale-in");
  observer.observe(el);
});

document.querySelectorAll(".hero-card").forEach((el) => {
  el.classList.add("slide-in-right");
  observer.observe(el);
});

document.querySelectorAll(".hero-copy").forEach((el) => {
  el.classList.add("slide-in-left");
  observer.observe(el);
});

// Parallax effect on scroll
let ticking = false;
window.addEventListener('scroll', () => {
  if (!ticking) {
    window.requestAnimationFrame(() => {
      const scrolled = window.pageYOffset;
      const parallaxElements = document.querySelectorAll('.hero-card, .glow');
      
      parallaxElements.forEach((el) => {
        const speed = 0.3;
        el.style.transform = `translateY(${scrolled * speed}px)`;
      });
      
      ticking = false;
    });
    ticking = true;
  }
});

// Mouse move effect for cards
document.querySelectorAll('.card').forEach(card => {
  card.addEventListener('mousemove', (e) => {
    const rect = card.getBoundingClientRect();
    const x = e.clientX - rect.left;
    const y = e.clientY - rect.top;
    
    const centerX = rect.width / 2;
    const centerY = rect.height / 2;
    
    const rotateX = (y - centerY) / 20;
    const rotateY = (centerX - x) / 20;
    
    card.style.transform = `translateY(-8px) scale(1.02) perspective(1000px) rotateX(${rotateX}deg) rotateY(${rotateY}deg)`;
  });
  
  card.addEventListener('mouseleave', () => {
    card.style.transform = '';
  });
});

// Floating animation for logo
const logo = document.querySelector('.logo');
if (logo) {
  let floatDirection = 1;
  setInterval(() => {
    const currentTransform = logo.style.transform;
    const currentY = parseFloat(currentTransform.match(/translateY\((-?\d+\.?\d*)px\)/)?.[1] || 0);
    
    if (currentY >= 3) floatDirection = -1;
    if (currentY <= -3) floatDirection = 1;
    
    logo.style.transform = `translateY(${currentY + (0.5 * floatDirection)}px)`;
  }, 50);
}

// Add ripple effect to buttons
document.querySelectorAll('.primary, .secondary, .nav-cta').forEach(button => {
  button.addEventListener('click', function(e) {
    const ripple = document.createElement('span');
    const rect = this.getBoundingClientRect();
    const size = Math.max(rect.width, rect.height);
    const x = e.clientX - rect.left - size / 2;
    const y = e.clientY - rect.top - size / 2;
    
    ripple.style.width = ripple.style.height = size + 'px';
    ripple.style.left = x + 'px';
    ripple.style.top = y + 'px';
    ripple.classList.add('ripple');
    
    this.appendChild(ripple);
    
    setTimeout(() => ripple.remove(), 600);
  });
});

// Smooth scroll for nav links
document.querySelectorAll('a[href^="#"]').forEach(anchor => {
  anchor.addEventListener('click', function (e) {
    e.preventDefault();
    const target = document.querySelector(this.getAttribute('href'));
    if (target) {
      target.scrollIntoView({
        behavior: 'smooth',
        block: 'start'
      });
    }
  });
});

// Web Analyzer
let db = null;
let charts = {};

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
