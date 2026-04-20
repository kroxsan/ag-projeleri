-- ============================================================
-- BLM4522 - Proje 5: Veri Temizleme ve ETL Süreçleri
-- Veritabanı: Northwind (PostgreSQL 17)
-- ============================================================


-- ============================================================
-- BÖLÜM 0: VERİ KALİTESİ ANALİZİ (Açık Tespiti)
-- ============================================================

SELECT 'Teslim edilmemiş sipariş' AS sorun, COUNT(*) FROM orders WHERE shipped_date IS NULL
UNION ALL
SELECT 'Bölgesi boş müşteri',      COUNT(*) FROM customers WHERE region IS NULL
UNION ALL
SELECT 'Bölgesi boş sipariş',      COUNT(*) FROM orders WHERE ship_region IS NULL
UNION ALL
SELECT 'Üretimi duran ürün',        COUNT(*) FROM products WHERE discontinued = 1
UNION ALL
SELECT 'Yöneticisi olmayan çalışan',COUNT(*) FROM employees WHERE reports_to IS NULL;


-- ============================================================
-- BÖLÜM 1: VERİ TEMİZLEME (Extract & Clean)
-- ============================================================

-- 1.1 Boş region değerlerini 'Bilinmiyor' ile doldur
UPDATE customers
SET region = 'Bilinmiyor'
WHERE region IS NULL;

UPDATE orders
SET ship_region = 'Bilinmiyor'
WHERE ship_region IS NULL;

-- 1.2 Teslim edilmemiş siparişleri işaretle
ALTER TABLE orders ADD COLUMN IF NOT EXISTS teslimat_durumu TEXT;

UPDATE orders
SET teslimat_durumu = CASE
    WHEN shipped_date IS NULL THEN 'Beklemede'
    ELSE 'Teslim Edildi'
END;

-- 1.3 Üretimi duran ürünleri işaretle
ALTER TABLE products ADD COLUMN IF NOT EXISTS urun_durumu TEXT;

UPDATE products
SET urun_durumu = CASE
    WHEN discontinued = 1 THEN 'Üretim Dışı'
    ELSE 'Aktif'
END;

-- Temizlik sonucunu doğrula
SELECT teslimat_durumu, COUNT(*) FROM orders GROUP BY teslimat_durumu;
SELECT urun_durumu, COUNT(*) FROM products GROUP BY urun_durumu;


-- ============================================================
-- BÖLÜM 2: VERİ DÖNÜŞTÜRME (Transform)
-- ============================================================

-- 2.1 Müşteri harcama segmenti hesapla
CREATE TABLE IF NOT EXISTS musteri_segment AS
SELECT
    c.customer_id,
    c.company_name,
    c.country,
    COUNT(o.order_id)              AS siparis_sayisi,
    ROUND(SUM(od.unit_price * od.quantity * (1 - od.discount))::NUMERIC, 2) AS toplam_harcama,
    CASE
        WHEN SUM(od.unit_price * od.quantity) >= 10000 THEN 'VIP'
        WHEN SUM(od.unit_price * od.quantity) >= 5000  THEN 'Standart'
        ELSE 'Düşük'
    END AS segment
FROM customers c
LEFT JOIN orders o     ON c.customer_id = o.customer_id
LEFT JOIN order_details od ON o.order_id = od.order_id
GROUP BY c.customer_id, c.company_name, c.country;

-- Segment dağılımını görüntüle
SELECT segment, COUNT(*) FROM musteri_segment GROUP BY segment;

-- ============================================================
-- BÖLÜM 2.2: MULTI-SOURCE VERİ STANDARDİZASYONU
-- ============================================================

-- 2.2.1 Farklı kaynaktan gelen müşteri verisini simüle et (CRM sistemi gibi)
CREATE TABLE IF NOT EXISTS external_customers AS
SELECT 
    customer_id,
    company_name,
    CASE 
        WHEN country = 'USA' THEN 'US'
        WHEN country = 'UK' THEN 'GB'
        ELSE country
    END AS country_code,
    region
FROM customers;

-- NOT: Bu tablo, farklı bir sistemden gelen ve farklı formatta tutulan veriyi simüle eder.

-- 2.2.2 Veri standardizasyonu (ülke kodlarını tek formata getir)
CREATE TABLE IF NOT EXISTS standardized_customers AS
SELECT
    c.customer_id,
    c.company_name,
    
    -- Ana sistem (customers) → full country name
    CASE 
        WHEN c.country = 'USA' THEN 'United States'
        WHEN c.country = 'UK' THEN 'United Kingdom'
        ELSE c.country
    END AS country_standardized,

    -- External sistem → code'dan full name'e çeviri
    CASE 
        WHEN e.country_code = 'US' THEN 'United States'
        WHEN e.country_code = 'GB' THEN 'United Kingdom'
        ELSE e.country_code
    END AS external_country_standardized,

    c.region

FROM customers c
LEFT JOIN external_customers e 
    ON c.customer_id = e.customer_id;

-- 2.2.3 Kontrol
SELECT 
    country_standardized, 
    external_country_standardized, 
    COUNT(*) 
FROM standardized_customers
GROUP BY country_standardized, external_country_standardized;


-- ============================================================
-- BÖLÜM 3: VERİ YÜKLEME (Load)
-- ============================================================

CREATE TABLE IF NOT EXISTS etl_ozet AS
SELECT
    p.product_id,
    p.product_name,
    p.urun_durumu,
    c.category_name,
    p.unit_price,
    SUM(od.quantity)               AS toplam_satilan,
    ROUND(SUM(od.unit_price * od.quantity)::NUMERIC, 2) AS toplam_gelir
FROM products p
JOIN categories c      ON p.category_id  = c.category_id
LEFT JOIN order_details od ON p.product_id = od.product_id
GROUP BY p.product_id, p.product_name, p.urun_durumu, c.category_name, p.unit_price
ORDER BY toplam_gelir DESC;

SELECT COUNT(*) AS yuklenen_kayit FROM etl_ozet;


-- ============================================================
-- BÖLÜM 4: VERİ KALİTESİ RAPORU
-- ============================================================

SELECT * FROM (VALUES
    ('Toplam müşteri',        (SELECT COUNT(*)::TEXT FROM customers)),
    ('Bölgesi doldurulan',    (SELECT COUNT(*)::TEXT FROM customers WHERE region = 'Bilinmiyor')),
    ('Beklemedeki sipariş',   (SELECT COUNT(*)::TEXT FROM orders WHERE teslimat_durumu = 'Beklemede')),
    ('Üretim dışı ürün',      (SELECT COUNT(*)::TEXT FROM products WHERE urun_durumu = 'Üretim Dışı')),
    ('Müşteri segment kaydı', (SELECT COUNT(*)::TEXT FROM musteri_segment)),
    ('ETL özet kaydı',        (SELECT COUNT(*)::TEXT FROM etl_ozet))
) AS rapor(baslik, deger);
