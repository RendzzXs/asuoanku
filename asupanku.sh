#!/bin/bash
# ============================================
#   🎬 ASUPANKU — VIDEO SHARE PLATFORM
#   Upload • View Counter • Hidden Admin Panel
# ============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}❌ Harus root!${NC}"; exit 1; }

clear
echo -e "${CYAN}╔════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  🎬 ASUPANKU — INSTALLER                   ║${NC}"
echo -e "${CYAN}║  Upload Video • View • Admin x-panel-core  ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════╝${NC}"
echo ""

read -p "👉 Subdomain (contoh: asupan.domain.com): " SUBDOMAIN
[[ -z "$SUBDOMAIN" ]] && { echo -e "${RED}❌ Kosong!${NC}"; exit 1; }

read -p "👉 Email SSL: " EMAIL
[[ -z "$EMAIL" ]] && EMAIL="admin@$SUBDOMAIN"

read -s -p "👉 Password Admin Panel [admin123]: " ADMIN_PASS
echo ""
ADMIN_PASS=${ADMIN_PASS:-admin123}

DB_PASS=$(openssl rand -hex 12)
DB_NAME="asupan_$(echo $SUBDOMAIN | tr '.' '_' | cut -c1-15)"
WEB_ROOT="/var/www/$SUBDOMAIN"
NGINX_CONF="/etc/nginx/sites-available/$SUBDOMAIN"

echo ""
echo -e "${CYAN}📋 Summary:${NC}"
echo "  Subdomain : $SUBDOMAIN"
echo "  Admin Path: /x-panel-core"
echo "  Admin Pass: $ADMIN_PASS"
echo ""
read -p "Lanjut? (y/n): " C
[[ "$C" != "y" && "$C" != "Y" ]] && exit 0

# ============ STEP 1: PACKAGES ============
echo ""
echo -e "${CYAN}[1/6] Install packages...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt update -qq 2>/dev/null
apt install nginx php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-curl php8.3-xml php8.3-zip php8.3-gd mysql-server curl wget unzip ffmpeg -y -qq 2>/dev/null

rm -f /etc/mysql/FROZEN 2>/dev/null
systemctl enable mysql nginx php8.3-fpm >/dev/null 2>&1
systemctl start mysql nginx php8.3-fpm >/dev/null 2>&1

if ! systemctl is-active --quiet mysql; then
    systemctl stop mysql >/dev/null 2>&1
    apt purge mysql-server mysql-server-8.0 mysql-client mysql-common -y >/dev/null 2>&1
    rm -rf /var/lib/mysql /etc/mysql
    apt install mysql-server -y -qq >/dev/null 2>&1
    systemctl start mysql >/dev/null 2>&1
    sleep 5
fi

for i in {1..15}; do
    [[ -S /var/run/mysqld/mysqld.sock ]] && break
    sleep 1
done

systemctl is-active --quiet mysql && echo -e "${GREEN}  ✓ MySQL OK${NC}" || { echo -e "${RED}  ✗ MySQL gagal!${NC}"; exit 1; }

# ============ STEP 2: DATABASE ============
echo -e "${CYAN}[2/6] Database...${NC}"
mysql -e "DROP DATABASE IF EXISTS \`$DB_NAME\`;" 2>/dev/null
mysql -e "CREATE DATABASE \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -e "CREATE USER IF NOT EXISTS 'asupan'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO 'asupan'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

mysql "$DB_NAME" << 'SQLEOF'
CREATE TABLE videos (
    id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    filename VARCHAR(255) NOT NULL,
    filesize INT DEFAULT 0,
    views INT DEFAULT 0,
    status ENUM('pending','approved','rejected') DEFAULT 'approved',
    uploader_ip VARCHAR(45),
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE settings (
    k VARCHAR(50) PRIMARY KEY,
    v TEXT
);
INSERT INTO settings VALUES 
('admin_password', 'ADMIN_HASH_PLACEHOLDER'),
('site_name', 'AsupanKu');
SQLEOF

ADMIN_HASH=$(php -r "echo password_hash('$ADMIN_PASS', PASSWORD_BCRYPT);")
mysql "$DB_NAME" -e "UPDATE settings SET v='$ADMIN_HASH' WHERE k='admin_password';"
echo -e "${GREEN}  ✓ Database OK${NC}"

# ============ STEP 3: FOLDER ============
echo -e "${CYAN}[3/6] Folder...${NC}"
[[ -d "$WEB_ROOT" ]] && mv "$WEB_ROOT" "/var/www/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WEB_ROOT"/{api,includes,assets/css,assets/js,uploads,x-panel-core}
echo -e "${GREEN}  ✓ Folder OK${NC}"

# ============ STEP 4: CONFIG ============
echo -e "${CYAN}[4/6] Config...${NC}"
cat > "$WEB_ROOT/includes/config.php" << PHPEOF
<?php
session_start();
date_default_timezone_set('Asia/Jakarta');

define('DB_HOST', 'localhost');
define('DB_NAME', '$DB_NAME');
define('DB_USER', 'asupan');
define('DB_PASS', '$DB_PASS');
define('SITE_URL', 'https://$SUBDOMAIN');
define('SITE_NAME', 'AsupanKu');
define('ADMIN_PATH', 'x-panel-core');

try {
    \$pdo = new PDO("mysql:host=".DB_HOST.";dbname=".DB_NAME.";charset=utf8mb4", DB_USER, DB_PASS, [
        PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
} catch (PDOException \$e) { die("DB Error: " . \$e->getMessage()); }

function isAdmin() { return isset(\$_SESSION['admin_logged']) && \$_SESSION['admin_logged'] === true; }
function requireAdmin() { if (!isAdmin()) { header('Location: /'.ADMIN_PATH.'/login.php'); exit; } }
function csrf() { if (empty(\$_SESSION['csrf'])) \$_SESSION['csrf'] = bin2hex(random_bytes(32)); return \$_SESSION['csrf']; }
function checkCsrf(\$t) { return isset(\$_SESSION['csrf']) && hash_equals(\$_SESSION['csrf'], \$t); }
function getSetting(\$pdo, \$k, \$default = '') {
    \$s = \$pdo->prepare("SELECT v FROM settings WHERE k=?"); \$s->execute([\$k]);
    \$r = \$s->fetch(); return \$r ? \$r['v'] : \$default;
}
function formatNumber(\$n) {
    if (\$n >= 1000000) return round(\$n/1000000, 1) . 'M';
    if (\$n >= 1000) return round(\$n/1000, 1) . 'K';
    return \$n;
}
PHPEOF
echo -e "${GREEN}  ✓ Config OK${NC}"

# ============ STEP 5: UI (CSS/JS) ============
echo -e "${CYAN}[5/6] UI Assets...${NC}"

# CSS LENGKAP
cat > "$WEB_ROOT/assets/css/style.css" << 'CSSEOF'
:root { --bg: #0a0a0f; --bg-card: #15151f; --text: #f0f0f5; --text-muted: #888899; --border: rgba(255,255,255,0.08); --primary: #ff0055; --primary-2: #ff4488; --success: #00e676; --danger: #ff4757; --info: #29b6f6; }
* { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Plus Jakarta Sans', -apple-system, sans-serif; }
body { background: var(--bg); color: var(--text); line-height: 1.6; min-height: 100vh; }
a { color: inherit; text-decoration: none; }
img { max-width: 100%; display: block; }

/* NAVBAR */
.navbar { position: sticky; top: 0; z-index: 100; background: rgba(10,10,15,0.95); backdrop-filter: blur(20px); border-bottom: 1px solid var(--border); padding: 14px 20px; }
.navbar-inner { max-width: 1200px; margin: 0 auto; display: flex; align-items: center; justify-content: space-between; gap: 20px; }
.navbar-logo { display: flex; align-items: center; gap: 10px; font-size: 1.3em; font-weight: 800; }
.navbar-logo-icon { width: 38px; height: 38px; border-radius: 10px; background: linear-gradient(135deg, var(--primary), var(--primary-2)); display: flex; align-items: center; justify-content: center; color: #fff; font-size: 1.2em; }
.navbar-logo-text span { color: var(--primary); }
.navbar-search { flex: 1; max-width: 400px; }
.navbar-search input { width: 100%; padding: 10px 16px; border: 1px solid var(--border); border-radius: 24px; background: var(--bg-card); color: var(--text); outline: none; }
.navbar-search input:focus { border-color: var(--primary); }
.navbar-btn { padding: 10px 20px; border-radius: 24px; background: var(--primary); color: #fff; font-weight: 700; text-decoration: none; display: inline-flex; align-items: center; gap: 8px; }

/* CONTAINER */
.container { max-width: 1200px; margin: 0 auto; padding: 30px 20px; }
.hero { text-align: center; padding: 40px 20px; }
.hero h1 { font-size: 2.5em; margin-bottom: 10px; background: linear-gradient(135deg, #fff, var(--primary)); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
.hero p { color: var(--text-muted); font-size: 1.1em; }

/* VIDEO GRID */
.video-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: 20px; margin-top: 30px; }
.video-card { background: var(--bg-card); border-radius: 16px; overflow: hidden; border: 1px solid var(--border); transition: 0.3s; display: block; }
.video-card:hover { transform: translateY(-5px); border-color: var(--primary); box-shadow: 0 10px 30px rgba(255,0,85,0.2); }
.video-thumb { position: relative; aspect-ratio: 16/9; background: #000; }
.video-thumb video { width: 100%; height: 100%; object-fit: cover; }
.video-views-badge { position: absolute; bottom: 8px; right: 8px; background: rgba(0,0,0,0.8); color: #fff; padding: 4px 8px; border-radius: 6px; font-size: 0.8em; font-weight: 700; display: flex; align-items: center; gap: 5px; }
.video-info { padding: 15px; }
.video-title { font-weight: 700; font-size: 1em; margin-bottom: 8px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }
.video-meta { color: var(--text-muted); font-size: 0.8em; }

/* WATCH PAGE */
.watch-layout { display: grid; grid-template-columns: 1fr 350px; gap: 24px; max-width: 1200px; margin: 0 auto; padding: 20px; }
.watch-main video { width: 100%; border-radius: 16px; background: #000; }
.watch-title { font-size: 1.5em; font-weight: 800; margin: 20px 0 10px; }
.watch-meta { display: flex; gap: 20px; color: var(--text-muted); font-size: 0.9em; padding-bottom: 15px; border-bottom: 1px solid var(--border); margin-bottom: 15px; }
.watch-desc { color: var(--text-muted); font-size: 0.95em; white-space: pre-wrap; line-height: 1.6; }

/* UPLOAD FORM */
.upload-wrap { max-width: 600px; margin: 30px auto; background: var(--bg-card); padding: 30px; border-radius: 20px; border: 1px solid var(--border); }
.form-group { margin-bottom: 18px; }
.form-group label { display: block; margin-bottom: 8px; font-weight: 600; font-size: 0.9em; }
.form-group input, .form-group textarea { width: 100%; padding: 13px 16px; border: 1px solid var(--border); border-radius: 12px; background: var(--bg); color: var(--text); outline: none; font-family: inherit; }
.form-group input:focus, .form-group textarea:focus { border-color: var(--primary); }
.form-group textarea { resize: vertical; min-height: 100px; }
.file-upload { border: 2px dashed var(--border); border-radius: 16px; padding: 40px; text-align: center; cursor: pointer; transition: 0.2s; background: rgba(0,0,0,0.2); }
.file-upload:hover { border-color: var(--primary); background: rgba(255,0,85,0.05); }
.file-upload i { font-size: 3em; color: var(--primary); margin-bottom: 10px; }
.file-upload input { display: none; }
.btn { padding: 14px 24px; border-radius: 12px; border: none; font-weight: 700; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 8px; transition: 0.2s; font-family: inherit; font-size: 1em; }
.btn-primary { background: var(--primary); color: #fff; }
.btn-primary:hover { background: var(--primary-2); }
.btn-block { width: 100%; }
.btn-danger { background: var(--danger); color: #fff; }
.btn-success { background: var(--success); color: #000; }
.btn-sm { padding: 6px 12px; font-size: 0.85em; }

/* ALERTS */
.alert { padding: 14px 18px; border-radius: 12px; margin-bottom: 20px; font-size: 0.9em; }
.alert-success { background: rgba(0,230,118,0.1); color: var(--success); border-left: 4px solid var(--success); }
.alert-error { background: rgba(255,71,87,0.1); color: var(--danger); border-left: 4px solid var(--danger); }

/* ADMIN PANEL */
.admin-header { background: #1a0a1f; padding: 15px 20px; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid var(--primary); }
.admin-nav { display: flex; gap: 10px; }
.admin-nav a { padding: 8px 16px; border-radius: 8px; font-weight: 600; color: var(--text-muted); }
.admin-nav a:hover, .admin-nav a.active { color: #fff; background: rgba(255,0,85,0.2); }
.admin-table { width: 100%; border-collapse: collapse; margin-top: 20px; background: var(--bg-card); border-radius: 12px; overflow: hidden; }
.admin-table th, .admin-table td { padding: 15px; text-align: left; border-bottom: 1px solid var(--border); font-size: 0.9em; }
.admin-table th { background: rgba(255,0,85,0.1); color: var(--primary); font-weight: 700; }
.admin-table tr:hover { background: rgba(255,255,255,0.02); }

@media (max-width: 768px) {
    .watch-layout { grid-template-columns: 1fr; }
    .video-grid { grid-template-columns: 1fr 1fr; gap: 10px; }
    .navbar-search { display: none; }
}
CSSEOF

# MAIN JS
cat > "$WEB_ROOT/assets/js/main.js" << 'JSEOF'
document.addEventListener('DOMContentLoaded', function() {
    const fileInput = document.getElementById('videoFile');
    const fileUpload = document.getElementById('fileUpload');
    const filePreview = document.getElementById('filePreview');
    const fileName = document.getElementById('fileName');
    
    if (fileUpload) {
        fileUpload.addEventListener('click', () => fileInput.click());
        fileInput.addEventListener('change', () => {
            if (fileInput.files.length > 0) {
                fileName.textContent = fileInput.files[0].name + ' (Siap Upload)';
                filePreview.style.display = 'block';
            }
        });
    }
});
JSEOF
echo -e "${GREEN}  ✓ UI OK${NC}"

# ============ STEP 6: PAGES ============
echo -e "${CYAN}[6/6] Halaman...${NC}"

# HEADER & FOOTER
cat > "$WEB_ROOT/includes/header.php" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title><?= $pageTitle ?? 'Home' ?> — <?= SITE_NAME ?></title>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700;800&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
<link rel="stylesheet" href="/assets/css/style.css">
</head>
<body>
HTMLEOF

cat > "$WEB_ROOT/includes/navbar.php" << 'HTMLEOF'
<nav class="navbar">
    <div class="navbar-inner">
        <a href="/" class="navbar-logo">
            <div class="navbar-logo-icon"><i class="fas fa-play"></i></div>
            <div class="navbar-logo-text">Asupan<span>Ku</span></div>
        </a>
        <form class="navbar-search" method="GET" action="/">
            <input type="text" name="q" placeholder="Cari video asupan..." value="<?= htmlspecialchars($_GET['q'] ?? '') ?>">
        </form>
        <a href="/upload.php" class="navbar-btn"><i class="fas fa-cloud-upload-alt"></i> Upload</a>
    </div>
</nav>
HTMLEOF

cat > "$WEB_ROOT/includes/footer.php" << 'HTMLEOF'
<div style="text-align:center; padding: 40px 20px; color:var(--text-muted); border-top:1px solid var(--border); margin-top: 50px;">
    <p>&copy; <?= date('Y') ?> <?= SITE_NAME ?>. All rights reserved.</p>
</div>
<script src="/assets/js/main.js"></script>
</body>
</html>
HTMLEOF

# HOME PAGE
cat > "$WEB_ROOT/index.php" << 'PHPEOF'
<?php
require_once __DIR__ . '/includes/config.php';
$pageTitle = 'Home';

$q = trim($_GET['q'] ?? '');
$sql = "SELECT * FROM videos WHERE status='approved'";
$params = [];
if ($q) {
    $sql .= " AND title LIKE ?";
    $params[] = "%$q%";
}
$sql .= " ORDER BY id DESC";
$st = $pdo->prepare($sql);
$st->execute($params);
$videos = $st->fetchAll();

include __DIR__ . '/includes/header.php';
include __DIR__ . '/includes/navbar.php';
?>
<div class="container">
    <div class="hero">
        <h1>Asupan Video Terbaru</h1>
        <p>Kumpulan video asupan viral, update setiap hari!</p>
    </div>

    <?php if ($q): ?>
        <h3>Hasil pencarian untuk: "<?= htmlspecialchars($q) ?>"</h3>
    <?php endif; ?>

    <div class="video-grid">
        <?php if (empty($videos)): ?>
            <div style="grid-column: 1/-1; text-align:center; padding:50px; color:var(--text-muted);">
                <i class="fas fa-folder-open" style="font-size:3em; margin-bottom:15px;"></i>
                <h3>Belum ada video</h3>
                <p>Jadilah yang pertama upload!</p>
            </div>
        <?php else: ?>
            <?php foreach ($videos as $v): ?>
            <a href="/watch.php?id=<?= $v['id'] ?>" class="video-card">
                <div class="video-thumb">
                    <video preload="metadata" muted>
                        <source src="/uploads/<?= htmlspecialchars($v['filename']) ?>#t=1" type="video/mp4">
                    </video>
                    <div class="video-views-badge">
                        <i class="fas fa-eye"></i> <?= formatNumber($v['views']) ?>
                    </div>
                </div>
                <div class="video-info">
                    <div class="video-title"><?= htmlspecialchars($v['title']) ?></div>
                    <div class="video-meta">
                        <i class="fas fa-clock"></i> <?= date('d M Y', strtotime($v['created_at'])) ?>
                    </div>
                </div>
            </a>
            <?php endforeach; ?>
        <?php endif; ?>
    </div>
</div>
<?php include __DIR__ . '/includes/footer.php'; ?>
PHPEOF

# WATCH PAGE (View Increment)
cat > "$WEB_ROOT/watch.php" << 'PHPEOF'
<?php
require_once __DIR__ . '/includes/config.php';
$id = (int)($_GET['id'] ?? 0);

$s = $pdo->prepare("SELECT * FROM videos WHERE id=? AND status='approved'");
$s->execute([$id]);
$v = $s->fetch();

if (!$v) {
    header('Location: /');
    exit;
}

// Increment views (hanya kalau belum lihat di session ini)
$sessKey = 'viewed_' . $id;
if (!isset($_SESSION[$sessKey])) {
    $pdo->prepare("UPDATE videos SET views = views + 1 WHERE id=?")->execute([$id]);
    $_SESSION[$sessKey] = time();
    $v['views']++;
}

// Rekomendasi video
$related = $pdo->prepare("SELECT * FROM videos WHERE status='approved' AND id != ? ORDER BY views DESC LIMIT 5");
$related->execute([$id]);
$related = $related->fetchAll();

$pageTitle = $v['title'];
include __DIR__ . '/includes/header.php';
include __DIR__ . '/includes/navbar.php';
?>
<div class="watch-layout">
    <div class="watch-main">
        <video controls autoplay>
            <source src="/uploads/<?= htmlspecialchars($v['filename']) ?>" type="video/mp4">
        </video>
        
        <h1 class="watch-title"><?= htmlspecialchars($v['title']) ?></h1>
        
        <div class="watch-meta">
            <span><i class="fas fa-eye"></i> <?= number_format($v['views']) ?> views</span>
            <span><i class="fas fa-calendar"></i> <?= date('d M Y', strtotime($v['created_at'])) ?></span>
        </div>

        <div class="watch-desc">
            <?= nl2br(htmlspecialchars($v['description'] ?? 'Tidak ada deskripsi.')) ?>
        </div>
    </div>

    <div class="watch-sidebar">
        <h3 style="margin-bottom:15px;font-size:1.1em"><i class="fas fa-fire" style="color:var(--primary)"></i> Video Terkait</h3>
        <?php foreach ($related as $r): ?>
            <a href="/watch.php?id=<?= $r['id'] ?>" style="display:flex; gap:12px; margin-bottom:15px; padding:8px; border-radius:10px; transition:0.2s;" onmouseover="this.style.background='var(--bg-card)'" onmouseout="this.style.background='transparent'">
                <div style="width:120px; flex-shrink:0; aspect-ratio:16/9; border-radius:8px; overflow:hidden; background:#000;">
                    <video preload="metadata" muted style="width:100%;height:100%;object-fit:cover">
                        <source src="/uploads/<?= htmlspecialchars($r['filename']) ?>#t=1" type="video/mp4">
                    </video>
                </div>
                <div>
                    <div style="font-weight:700; font-size:0.9em; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; line-height:1.3; margin-bottom:5px;">
                        <?= htmlspecialchars($r['title']) ?>
                    </div>
                    <div style="font-size:0.8em; color:var(--text-muted)">
                        <i class="fas fa-eye"></i> <?= formatNumber($r['views']) ?> views
                    </div>
                </div>
            </a>
        <?php endforeach; ?>
    </div>
</div>
<?php include __DIR__ . '/includes/footer.php'; ?>
PHPEOF

# UPLOAD PAGE
cat > "$WEB_ROOT/upload.php" << 'PHPEOF'
<?php
require_once __DIR__ . '/includes/config.php';
$pageTitle = 'Upload Video';
$msg = ''; $err = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $title = trim($_POST['title'] ?? '');
    $desc = trim($_POST['description'] ?? '');
    
    if (!$title) {
        $err = 'Judul wajib diisi!';
    } elseif (!isset($_FILES['video']) || $_FILES['video']['error'] !== 0) {
        $err = 'Pilih file video yang valid!';
    } else {
        $file = $_FILES['video'];
        $ext = strtolower(pathinfo($file['name'], PATHINFO_EXTENSION));
        $allowed = ['mp4', 'webm', 'mkv', 'mov'];
        
        if (!in_array($ext, $allowed)) {
            $err = 'Format harus MP4, WEBM, MKV, atau MOV.';
        } elseif ($file['size'] > 100 * 1024 * 1024) { // 100MB limit
            $err = 'Maksimal ukuran video 100MB.';
        } else {
            $newName = time() . '_' . bin2hex(random_bytes(4)) . '.' . $ext;
            $target = __DIR__ . '/uploads/' . $newName;
            
            if (move_uploaded_file($file['tmp_name'], $target)) {
                $stmt = $pdo->prepare("INSERT INTO videos (title, description, filename, filesize, uploader_ip) VALUES (?,?,?,?,?)");
                $stmt->execute([$title, $desc, $newName, $file['size'], $_SERVER['REMOTE_ADDR']]);
                header('Location: /watch.php?id=' . $pdo->lastInsertId());
                exit;
            } else {
                $err = 'Gagal menyimpan file. Cek permission folder uploads.';
            }
        }
    }
}

include __DIR__ . '/includes/header.php';
include __DIR__ . '/includes/navbar.php';
?>
<div class="container">
    <div class="upload-wrap">
        <h1 style="margin-bottom:10px"><i class="fas fa-cloud-upload-alt" style="color:var(--primary)"></i> Upload Video</h1>
        <p style="color:var(--text-muted); margin-bottom:25px;">Bagikan asupan terbaikmu. Maksimal 100MB.</p>

        <?php if ($msg): ?><div class="alert alert-success"><?= $msg ?></div><?php endif; ?>
        <?php if ($err): ?><div class="alert alert-error"><?= $err ?></div><?php endif; ?>

        <form method="POST" enctype="multipart/form-data">
            <div class="form-group">
                <label>Judul Video</label>
                <input type="text" name="title" placeholder="Contoh: Asupan Hijabers Viral" required>
            </div>
            
            <div class="form-group">
                <label>Deskripsi</label>
                <textarea name="description" placeholder="Tulis deskripsi atau sumber video..."></textarea>
            </div>

            <div class="form-group">
                <label>File Video</label>
                <div class="file-upload" id="fileUpload">
                    <i class="fas fa-file-video"></i>
                    <strong>Klik atau Drag file ke sini</strong>
                    <small>Format: MP4, WEBM, MKV (Max 100MB)</small>
                    <input type="file" name="video" id="videoFile" accept="video/*" required>
                </div>
                <div id="filePreview" style="display:none; margin-top:10px; padding:10px; background:rgba(0,230,118,0.1); border-radius:8px; color:var(--success); font-weight:700;">
                    <i class="fas fa-check-circle"></i> <span id="fileName"></span>
                </div>
            </div>

            <button type="submit" class="btn btn-primary btn-block"><i class="fas fa-upload"></i> Upload Sekarang</button>
        </form>
    </div>
</div>
<?php include __DIR__ . '/includes/footer.php'; ?>
PHPEOF

echo -e "${GREEN}  ✓ Halaman Publik OK${NC}"

# ============ ADMIN PANEL ============
echo -e "${CYAN}📝 Admin Panel (x-panel-core)...${NC}"

# LOGIN ADMIN
cat > "$WEB_ROOT/x-panel-core/login.php" << 'PHPEOF'
<?php
require_once __DIR__ . '/../includes/config.php';
if (isAdmin()) { header('Location: /x-panel-core/'); exit; }
$error = '';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $pass = $_POST['password'] ?? '';
    $hash = getSetting($pdo, 'admin_password');
    
    if (password_verify($pass, $hash)) {
        $_SESSION['admin_logged'] = true;
        header('Location: /x-panel-core/');
        exit;
    } else {
        $error = 'Password salah!';
    }
}
?>
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Admin Access</title>
<link rel="stylesheet" href="/assets/css/style.css">
</head>
<body style="background:#050508">
<div style="min-height:100vh; display:flex; align-items:center; justify-content:center; padding:20px;">
    <div class="upload-wrap" style="max-width:400px; width:100%">
        <div style="text-align:center; margin-bottom:20px;">
            <i class="fas fa-lock" style="font-size:3em; color:var(--primary);"></i>
            <h2 style="margin-top:10px">Restricted Area</h2>
        </div>
        <?php if ($error): ?><div class="alert alert-error" style="text-align:center"><?= $error ?></div><?php endif; ?>
        <form method="POST">
            <div class="form-group">
                <input type="password" name="password" placeholder="Admin Password" required autofocus style="text-align:center; letter-spacing:3px;">
            </div>
            <button type="submit" class="btn btn-primary btn-block">Login</button>
        </form>
    </div>
</div>
</body>
</html>
PHPEOF

# DASHBOARD ADMIN
cat > "$WEB_ROOT/x-panel-core/index.php" << 'PHPEOF'
<?php
require_once __DIR__ . '/../includes/config.php';
requireAdmin();

$msg = '';
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action'])) {
    $vid = (int)$_POST['video_id'];
    if ($_POST['action'] === 'delete') {
        $s = $pdo->prepare("SELECT filename FROM videos WHERE id=?"); $s->execute([$vid]);
        $f = $s->fetch();
        if ($f) {
            @unlink(__DIR__ . '/../uploads/' . $f['filename']);
            $pdo->prepare("DELETE FROM videos WHERE id=?")->execute([$vid]);
            $msg = 'Video dihapus.';
        }
    } elseif ($_POST['action'] === 'edit') {
        $newTitle = trim($_POST['title']);
        $pdo->prepare("UPDATE videos SET title=? WHERE id=?")->execute([$newTitle, $vid]);
        $msg = 'Judul video diupdate.';
    }
}

$videos = $pdo->query("SELECT * FROM videos ORDER BY id DESC")->fetchAll();
$totalVideos = count($videos);
$totalViews = $pdo->query("SELECT SUM(views) FROM videos")->fetchColumn() ?: 0;
?>
<!DOCTYPE html>
<html lang="id">
<head>
<meta charset="UTF-8">
<title>Admin Dashboard - <?= SITE_NAME ?></title>
<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css">
<link rel="stylesheet" href="/assets/css/style.css">
</head>
<body class="admin-body">
<div class="admin-header">
    <div class="admin-logo"><i class="fas fa-shield-alt"></i> X-PANEL</div>
    <div class="admin-nav">
        <a href="/x-panel-core/" class="active"><i class="fas fa-video"></i> Videos</a>
        <a href="/" target="_blank"><i class="fas fa-external-link-alt"></i> Lihat Web</a>
        <a href="/x-panel-core/logout.php" style="color:var(--danger)"><i class="fas fa-sign-out-alt"></i> Logout</a>
    </div>
</div>

<div class="container">
    <?php if ($msg): ?><div class="alert alert-success"><?= $msg ?></div><?php endif; ?>

    <div style="display:grid; grid-template-columns:1fr 1fr; gap:20px; margin-bottom:30px;">
        <div style="background:var(--bg-card); padding:20px; border-radius:12px; border:1px solid var(--border);">
            <h3 style="color:var(--text-muted); font-size:0.9em; text-transform:uppercase;">Total Video</h3>
            <div style="ercasefont-size:2em; font-weight:800;">; colorTotal:var(--primary);"><?= Views number_format($totalVideos) ?></div>
        </div>
</h        <div style="background:var(--bg-card); padding:20px; border-radius:12px; border:1px solid var(--border);">
            <h3 style="color:var(--text-muted); font-size:0.9em; text-transform:upp3>
            <div style="font-size:2em; font-weight:800; color:var(--primary);"><?= number_format($totalViews) ?></div>
        </div>
    </div>

    <table class="admin-table">
        <thead>
            <tr>
                <th>ID</th>
                <th>Judul</th>
                <th>Views</th>
                <th>Tanggal</th>
                <th>Aksi</th>
            </tr>
        </thead>
        <tbody>
            <?php foreach ($videos as $v): ?>
            <tr>
                <td>#<?= $v['id'] ?></td>
                <td>
                    <form method="POST" style="display:flex; gap:5px;">
                        <input type="hidden" name="action" value="edit">
                        <input type="hidden" name="video_id" value="<?= $v['id'] ?>">
                        <input type="text" name="title" value="<?= htmlspecialchars($v['title']) ?>" style="background:transparent; border:1px solid var(--border); color:#fff; padding:4px; border-radius:4px; width:100%;">
                        <button type="submit" class="btn btn-sm" style="background:var(--info); color:#fff; padding:4px 8px;">✓</button>
                    </form>
                </td>
                <td><?= number_format($v['views']) ?></td>
                <td><?= date('d/m/y', strtotime($v['created_at'])) ?></td>
                <td>
                    <a href="/watch.php?id=<?= $v['id'] ?>" target="_blank" class="btn btn-sm" style="background:#333;">Lihat</a>
                    <form method="POST" style="display:inline;" onsubmit="return confirm('Hapus video ini permanen?')">
                        <input type="hidden" name="action" value="delete">
                        <input type="hidden" name="video_id" value="<?= $v['id'] ?>">
                        <button type="submit" class="btn btn-sm btn-danger">Hapus</button>
                    </form>
                </td>
            </tr>
            <?php endforeach; ?>
        </tbody>
    </table>
</div>
</body>
</html>
PHPEOF

# LOGOUT
cat > "$WEB_ROOT/x-panel-core/logout.php" << 'PHPEOF'
<?php
session_start();
session_destroy();
header('Location: /x-panel-core/login.php');
exit;
PHPEOF

echo -e "${GREEN}  ✓ Admin Panel OK${NC}"

# ============ NGINX CONFIG ============
echo -e "${CYAN}📝 Nginx config...${NC}"

cat > "$NGINX_CONF" << NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $SUBDOMAIN;
    root $WEB_ROOT;
    index index.php index.html;
    
    client_max_body_size 100M;
    
    location / { try_files \$uri \$uri/ =404; }
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
    
    # Jangan biarkan orang lihat list folder uploads
    location /uploads/ {
        autoindex off;
    }
}
NGINXEOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/ 2>/dev/null
[[ -f /etc/nginx/sites-enabled/default ]] && rm -f /etc/nginx/sites-enabled/default

if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx
    echo -e "${GREEN}  ✓ Nginx OK${NC}"
else
    echo -e "${RED}  ✗ Nginx error!${NC}"; nginx -t; exit 1
fi

# ============ FIX PERMISSIONS ============
chown -R www-data:www-data "$WEB_ROOT"
chmod -R 755 "$WEB_ROOT"
chmod -R 775 "$WEB_ROOT/uploads"
systemctl restart php8.3-fpm

# ============ SSL ============
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
DOMAIN_IP=$(dig +short A "$SUBDOMAIN" @8.8.8.8 2>/dev/null | head -1)
[[ -z "$DOMAIN_IP" ]] && DOMAIN_IP=$(getent ahostsv4 "$SUBDOMAIN" 2>/dev/null | awk '{print $1}' | head -1)

if [[ "$SERVER_IP" == "$DOMAIN_IP" ]] || [[ -f "/etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem" ]]; then
    apt install certbot python3-certbot-nginx -y -qq 2>/dev/null
    certbot --nginx -d "$SUBDOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect >/dev/null 2>&1
fi

PROTO="https"; [[ ! -f "/etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem" ]] && PROTO="http"

# ============ SELESAI ============
clear
echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ ASUPANKU BERHASIL DI-INSTALL!          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}🔗 URL Publik:${NC}"
echo -e "  Home    : $PROTO://$SUBDOMAIN"
echo -e "  Upload  : $PROTO://$SUBDOMAIN/upload.php"
echo ""
echo -e "${MAGENTA}🔒 Admin Panel (Hidden):${NC}"
echo -e "  URL  : $PROTO://$SUBDOMAIN/x-panel-core"
echo -e "  Pass : $ADMIN_PASS"
echo ""
echo -e "${YELLOW}📌 Catatan:${NC}"
echo -e "  • Upload max 100MB per video."
echo -e "  • Video yang diupload langsung muncul di home."
echo -e "  • View counter otomatis bertambah saat video ditonton."
echo ""
echo -e "${GREEN}🎉 Selesai! Kamu bisa langsung upload video pertama!${NC}"
