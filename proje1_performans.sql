-- ============================================================
-- BLM4522 - Proje 1: Veritabanı Performans Optimizasyonu ve İzleme
-- Veritabanı: DVDRental (PostgreSQL 17)
-- ============================================================

-- TEMİZLİK
DROP INDEX IF EXISTS idx_rental_customer;
DROP INDEX IF EXISTS idx_payment_customer;
DROP INDEX IF EXISTS idx_rental_inventory;
DROP INDEX IF EXISTS idx_film_title;
DROP INDEX IF EXISTS idx_gereksiz_ornek;
DROP ROLE IF EXISTS db_monitor;
DROP ROLE IF EXISTS db_admin;
DROP USER IF EXISTS monitor_user;
DROP USER IF EXISTS dba_user;

-- ============================================================
-- BÖLÜM 0: VERİTABANI İZLEME (DMV)
-- ============================================================

-- Tablo boyutları ve satır sayıları
SELECT relname AS tablo, n_live_tup AS satir_sayisi,
       pg_size_pretty(pg_total_relation_size(relid)) AS boyut
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- pg_stat_statements Windows'ta shared_preload_libraries ayarı gerektirir
-- Gerçek ortamda postgresql.conf'a eklenerek aktif edilir
-- DMV simülasyonu: pg_stat_user_tables ile sorgu istatistikleri
SELECT relname AS tablo,
       seq_scan          AS sıralı_tarama,
       idx_scan          AS indeks_tarama,
       n_live_tup        AS satir_sayisi
FROM pg_stat_user_tables
ORDER BY seq_scan DESC
LIMIT 5;
-- seq_scan yüksekse o tabloda indeks eksik demektir

-- Mevcut indeksler
SELECT indexname, tablename FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename;

-- ============================================================
-- BÖLÜM 1: SORGU OPTİMİZASYONU (EXPLAIN ANALYZE)
-- ============================================================

-- İndekssiz: Seq Scan — tüm tablo taraniyor
EXPLAIN ANALYZE
SELECT rental_id, rental_date FROM rental
WHERE customer_id = 148;

-- İndekssiz JOIN sorgusu
EXPLAIN ANALYZE
SELECT c.first_name, c.last_name, COUNT(r.rental_id) AS kira_sayisi
FROM customer c
JOIN rental r ON c.customer_id = r.customer_id
GROUP BY c.customer_id
ORDER BY kira_sayisi DESC
LIMIT 10;

-- ============================================================
-- BÖLÜM 2: İNDEKS YÖNETİMİ
-- ============================================================

-- Gereksiz indeks örneği: nadiren sorgulanan bir sütun
CREATE INDEX idx_gereksiz_ornek ON rental(last_update);

-- Gereksiz indeksi kaldır
DROP INDEX idx_gereksiz_ornek;

-- Gerekli indeksleri ekle
CREATE INDEX idx_rental_customer  ON rental(customer_id);
CREATE INDEX idx_payment_customer ON payment(customer_id);
CREATE INDEX idx_rental_inventory ON rental(inventory_id);
CREATE INDEX idx_film_title       ON film(title);

-- İndeks sonrası aynı sorgu: Index Scan — çok daha hızlı!
EXPLAIN ANALYZE
SELECT rental_id, rental_date FROM rental
WHERE customer_id = 148;

-- Eklenen indeksleri doğrula
SELECT indexname, tablename FROM pg_indexes
WHERE indexname LIKE 'idx_%';

-- ============================================================
-- BÖLÜM 3: SORGU İYİLEŞTİRME
-- ============================================================

-- SELECT * yerine sadece gereken sütunlar + CTE kullanımı
WITH musteri_harcama AS (
    SELECT customer_id,
           ROUND(SUM(amount)::NUMERIC, 2) AS toplam_odeme
    FROM payment
    GROUP BY customer_id
)
SELECT c.first_name, c.last_name, mh.toplam_odeme
FROM customer c
JOIN musteri_harcama mh ON c.customer_id = mh.customer_id
ORDER BY mh.toplam_odeme DESC
LIMIT 10;

-- ============================================================
-- BÖLÜM 4: VERİ YÖNETİCİSİ ROLLERİ
-- ============================================================

-- Sadece izleme yetkisi olan rol
CREATE ROLE db_monitor;
GRANT CONNECT ON DATABASE dvdrental TO db_monitor;
GRANT USAGE   ON SCHEMA public TO db_monitor;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO db_monitor;

CREATE USER monitor_user WITH PASSWORD 'Monitor@2024!';
GRANT db_monitor TO monitor_user;

-- Tam yetkili DBA rolü
CREATE ROLE db_admin;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO db_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO db_admin;

CREATE USER dba_user WITH PASSWORD 'DBA@2024!';
GRANT db_admin TO dba_user;

-- Rolleri doğrula
SELECT rolname, rolcanlogin FROM pg_roles
WHERE rolname IN ('db_monitor','monitor_user','db_admin','dba_user');

-- ============================================================
-- ÖZET RAPOR
-- ============================================================

SELECT * FROM (VALUES
    ('Yeni indeks sayısı',  '4'),
    ('Kaldırılan gereksiz indeks', '1'),
    ('rental satır sayısı', (SELECT n_live_tup FROM pg_stat_user_tables WHERE relname = 'rental')::TEXT),
    ('payment satır sayısı',(SELECT n_live_tup FROM pg_stat_user_tables WHERE relname = 'payment')::TEXT),
    ('Tanımlı rol sayısı',  (SELECT COUNT(*) FROM pg_roles
                             WHERE rolname IN ('db_monitor','monitor_user','db_admin','dba_user'))::TEXT)
) AS rapor(baslik, deger);
