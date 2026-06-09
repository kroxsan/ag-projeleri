-- ============================================================
-- BLM4522 - Proje 7: Veritabanı Yedekleme ve Otomasyon
-- Veritabanı: DVDRental (PostgreSQL 17)
-- ============================================================

-- TEMİZLİK
DROP TABLE IF EXISTS yedek_log;
DROP TABLE IF EXISTS yedek_dogrulama;
DROP FUNCTION IF EXISTS yedek_kayit(TEXT, TEXT, BIGINT);

-- ============================================================
-- BÖLÜM 0: MEVCUT YEDEKLEME DURUMU
-- ============================================================

-- Veritabanı boyutu
SELECT pg_database.datname,
       pg_size_pretty(pg_database_size(pg_database.datname)) AS boyut
FROM pg_database
WHERE datname = 'dvdrental';

-- Tablo bazlı boyutlar (neyin yedekleneceği)
SELECT relname AS tablo,
       pg_size_pretty(pg_total_relation_size(relid)) AS boyut,
       n_live_tup AS satir_sayisi
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- ============================================================
-- BÖLÜM 1: YEDEKLEME RAPORLAMA
-- ============================================================

-- Yedek loglarını tutan tablo
CREATE TABLE yedek_log (
    id           SERIAL PRIMARY KEY,
    yedek_turu   TEXT,
    durum        TEXT,
    boyut_mb     NUMERIC,
    baslangic    TIMESTAMPTZ,
    bitis        TIMESTAMPTZ,
    aciklama     TEXT
);

-- Yedek kayıt fonksiyonu
CREATE OR REPLACE FUNCTION yedek_kayit(
    p_tur TEXT, p_durum TEXT, p_boyut BIGINT
) RETURNS VOID AS $$
BEGIN
    INSERT INTO yedek_log(yedek_turu, durum, boyut_mb, baslangic, bitis, aciklama)
    VALUES (p_tur, p_durum,
            ROUND(p_boyut / 1024.0 / 1024.0, 2),
            NOW() - INTERVAL '5 minutes', NOW(),
            p_tur || ' yedekleme ' || p_durum);
END;
$$ LANGUAGE plpgsql;

-- Yedekleme senaryolarını simüle et
SELECT yedek_kayit('TAM',      'BASARILI',  pg_database_size('dvdrental'));
SELECT yedek_kayit('ARTIMSAL', 'BASARILI',  pg_database_size('dvdrental') / 10);
SELECT yedek_kayit('FARK',     'BASARILI',  pg_database_size('dvdrental') / 5);
SELECT yedek_kayit('TAM',      'BASARISIZ', 0);

-- Yedek loglarını görüntüle
SELECT id, yedek_turu, durum, boyut_mb, bitis
FROM yedek_log
ORDER BY bitis DESC;

-- ============================================================
-- BÖLÜM 2: OTOMATİK YEDEKLEME ZAMANLAMA (Simülasyon)
-- ============================================================

-- pg_cron Windows'ta desteklenmez
-- Gerçek ortamda Windows Task Scheduler veya pgAgent kullanılır
-- Zamanlanmış görev simülasyonu:
SELECT 'gece_tam_yedek'            AS gorev_adi,
       '0 2 * * * (Her gece 02:00)' AS zamanlama,
       'TAM yedek'                  AS komut,
       true                         AS aktif
UNION ALL
SELECT 'haftalik_tam_yedek',
       '0 3 * * 0 (Her Pazar 03:00)',
       'TAM yedek',
       true;

-- ============================================================
-- BÖLÜM 3: OTOMATİK YEDEKLEME UYARILARI
-- ============================================================

-- Başarılı/başarısız ayrımı
CREATE TABLE yedek_dogrulama AS
SELECT
    yedek_turu,
    COUNT(*)                                    AS toplam,
    COUNT(*) FILTER (WHERE durum = 'BASARILI')  AS basarili,
    COUNT(*) FILTER (WHERE durum = 'BASARISIZ') AS basarisiz
FROM yedek_log
GROUP BY yedek_turu;

SELECT * FROM yedek_dogrulama;

-- Başarısız yedek uyarısı
SELECT 'UYARI: ' || yedek_turu || ' yedeği başarısız!' AS uyari_mesaji,
       bitis AS zaman
FROM yedek_log
WHERE durum = 'BASARISIZ';

-- ============================================================
-- ÖZET RAPOR
-- ============================================================

SELECT * FROM (VALUES
    ('Toplam yedek kaydı', (SELECT COUNT(*)::TEXT FROM yedek_log)),
    ('Başarılı yedek',     (SELECT COUNT(*)::TEXT FROM yedek_log WHERE durum = 'BASARILI')),
    ('Başarısız yedek',    (SELECT COUNT(*)::TEXT FROM yedek_log WHERE durum = 'BASARISIZ')),
    ('Veritabanı boyutu',  (SELECT pg_size_pretty(pg_database_size('dvdrental'))))
) AS rapor(baslik, deger);
