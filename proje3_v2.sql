-- ============================================================
-- BLM4522 - Proje 3: Veritabanı Güvenliği ve Erişim Kontrolü
-- Veritabanı: DVDRental (PostgreSQL 17)
-- ============================================================


-- ============================================================
-- BAŞLANGIÇ: TEMİZLİK (Birden fazla çalıştırma için)
-- ============================================================

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM readonly_role, staff_role, manager_role;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM readonly_role, staff_role, manager_role;
REVOKE ALL ON SCHEMA public FROM readonly_role, staff_role, manager_role;
REVOKE ALL ON DATABASE dvdrental FROM readonly_role, staff_role, manager_role;
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM analyst_user, staff_user, manager_user;
REVOKE ALL ON DATABASE dvdrental FROM analyst_user, staff_user, manager_user;

DROP USER IF EXISTS analyst_user;
DROP USER IF EXISTS staff_user;
DROP USER IF EXISTS manager_user;
DROP ROLE IF EXISTS readonly_role;
DROP ROLE IF EXISTS staff_role;
DROP ROLE IF EXISTS manager_role;
DROP TABLE IF EXISTS audit_log;
DROP TRIGGER IF EXISTS trg_audit_customer ON customer;
DROP TRIGGER IF EXISTS trg_audit_payment ON payment;
DROP TRIGGER IF EXISTS trg_audit_rental ON rental;
DROP FUNCTION IF EXISTS audit_trigger_func();
DROP FUNCTION IF EXISTS musteri_ara(text);
ALTER TABLE customer DROP COLUMN IF EXISTS email_encrypted;


-- ============================================================
-- BÖLÜM 0: MEVCUT GÜVENLİK AÇIKLARININ TESPİTİ
-- ============================================================

-- Mevcut roller var mı?
SELECT rolname, rolcanlogin FROM pg_roles
WHERE rolname NOT LIKE 'pg_%' AND rolname != 'postgres';
-- Sonuç: Sadece postgres var, hiç rol tanımlanmamış!

-- Tablolarda yetki kısıtlaması var mı?
SELECT grantee, privilege_type, table_name
FROM information_schema.role_table_grants
WHERE table_name IN ('customer', 'payment', 'rental')
  AND grantee NOT IN ('postgres', 'PUBLIC');
-- Sonuç: 0 satır, hiçbir kısıtlama yok!

-- Şifrelenmiş alan var mı?
SELECT table_name, column_name
FROM information_schema.columns
WHERE column_name ILIKE '%encrypt%'
   OR column_name ILIKE '%hash%'
   OR column_name ILIKE '%secret%';
-- Sonuç: 0 satır, tüm hassas veriler düz metin!

-- Hassas verilere örnek: email açıkta!
SELECT first_name, last_name, email FROM customer LIMIT 3;


-- ============================================================
-- BÖLÜM 1: ERİŞİM YÖNETİMİ (SQL Authentication & RBAC)
-- ============================================================

-- Rolleri oluştur
CREATE ROLE readonly_role;
CREATE ROLE staff_role;
CREATE ROLE manager_role;

-- Yetkileri ata
-- Sadece okuma
GRANT CONNECT ON DATABASE dvdrental TO readonly_role;
GRANT USAGE ON SCHEMA public TO readonly_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_role;

-- Personel: müşteri ve kiralama işlemleri
GRANT CONNECT ON DATABASE dvdrental TO staff_role;
GRANT USAGE ON SCHEMA public TO staff_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO staff_role;
GRANT INSERT, UPDATE ON customer, rental, payment TO staff_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO staff_role;

-- Müdür: film yönetimi
GRANT CONNECT ON DATABASE dvdrental TO manager_role;
GRANT USAGE ON SCHEMA public TO manager_role;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO manager_role;
GRANT INSERT, UPDATE, DELETE ON film, inventory, film_actor, film_category TO manager_role;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO manager_role;

-- Kullanıcıları oluştur ve rollere ata
CREATE USER analyst_user WITH PASSWORD 'Analyst@2024!';
CREATE USER staff_user   WITH PASSWORD 'Staff@2024!';
CREATE USER manager_user WITH PASSWORD 'Manager@2024!';

GRANT readonly_role TO analyst_user;
GRANT staff_role    TO staff_user;
GRANT manager_role  TO manager_user;

-- Rolleri doğrula
SELECT rolname, rolcanlogin FROM pg_roles
WHERE rolname IN ('readonly_role','staff_role','manager_role',
                  'analyst_user','staff_user','manager_user');

-- Yetkileri doğrula
SELECT grantee, table_name, privilege_type
FROM information_schema.role_table_grants
WHERE grantee IN ('readonly_role','staff_role','manager_role')
ORDER BY grantee, table_name;

-- ERİŞİM TESTİ:
-- Aşağıdaki komutu terminalde çalıştırarak analyst_user ile bağlan:
-- psql -d dvdrental -U analyst_user
-- SELECT * FROM customer LIMIT 3;         -- ÇALIŞMALI
-- INSERT INTO film(title) VALUES ('Test'); -- HATA VERMELİ: permission denied


-- ============================================================
-- BÖLÜM 2: VERİ ŞİFRELEME
-- ============================================================

-- pgcrypto eklentisini yükle
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Şifreli veri için sütun ekle
ALTER TABLE customer ADD COLUMN IF NOT EXISTS email_encrypted BYTEA;

-- Mevcut email verilerini şifrele
UPDATE customer
SET email_encrypted = pgp_sym_encrypt(email, 'GizliAnahtar2024!');

-- Karşılaştır: düz metin (orijinal) vs şifreli (yeni)
SELECT customer_id, first_name, last_name,
       email            AS duz_metin_email,
       email_encrypted  AS sifreli_email
FROM customer LIMIT 3;

-- Yetkili kullanıcı şifreyi çözer
SELECT customer_id, first_name,
       pgp_sym_decrypt(email_encrypted, 'GizliAnahtar2024!') AS gercek_email
FROM customer LIMIT 5;

-- ============================================================
-- BÖLÜM 3: SQL INJECTION TESTLERİ
-- ============================================================

-- SALDIRI GÖSTERİMİ: Güvensiz sorgu (tüm tabloyu döküyor!)
SELECT * FROM customer
WHERE customer_id::TEXT = '' OR '1'='1'
LIMIT 5;
-- Sonuç: Tüm müşteriler listelendi — bu ciddi bir güvenlik açığı!

-- KORUNMA 1: Prepared Statement
PREPARE guvenli_sorgu (INT) AS
    SELECT customer_id, first_name, last_name
    FROM customer
    WHERE customer_id = $1;

EXECUTE guvenli_sorgu(1);                    -- Normal kullanım
EXECUTE guvenli_sorgu(0);                    -- Injection denemesi: 0 satır döner

DEALLOCATE guvenli_sorgu;

-- ============================================================
-- BÖLÜM 4: AUDIT LOGLARI
-- ============================================================

-- Audit log tablosu
CREATE TABLE IF NOT EXISTS audit_log (
    id          SERIAL PRIMARY KEY,
    tablo_adi   TEXT,
    islem       TEXT,
    kullanici   TEXT,
    eski_deger  JSONB,
    yeni_deger  JSONB,
    islem_zamani TIMESTAMPTZ DEFAULT NOW()
);

-- Trigger fonksiyonu
CREATE OR REPLACE FUNCTION audit_trigger_func()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log(tablo_adi, islem, kullanici, yeni_deger)
        VALUES (TG_TABLE_NAME, TG_OP, current_user, row_to_json(NEW)::JSONB);
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log(tablo_adi, islem, kullanici, eski_deger, yeni_deger)
        VALUES (TG_TABLE_NAME, TG_OP, current_user, row_to_json(OLD)::JSONB, row_to_json(NEW)::JSONB);
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log(tablo_adi, islem, kullanici, eski_deger)
        VALUES (TG_TABLE_NAME, TG_OP, current_user, row_to_json(OLD)::JSONB);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Kritik tablolara trigger ekle
DROP TRIGGER IF EXISTS trg_audit_customer ON customer;
DROP TRIGGER IF EXISTS trg_audit_payment  ON payment;
DROP TRIGGER IF EXISTS trg_audit_rental   ON rental;

CREATE TRIGGER trg_audit_customer
    AFTER INSERT OR UPDATE OR DELETE ON customer
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

CREATE TRIGGER trg_audit_payment
    AFTER INSERT OR UPDATE OR DELETE ON payment
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

CREATE TRIGGER trg_audit_rental
    AFTER INSERT OR UPDATE OR DELETE ON rental
    FOR EACH ROW EXECUTE FUNCTION audit_trigger_func();

-- Audit log testi
INSERT INTO customer(store_id, first_name, last_name, address_id, activebool, create_date, active)
VALUES (1, 'Test', 'Kullanici', 5, TRUE, NOW(), 1);

UPDATE customer SET first_name = 'Guncellendi' WHERE last_name = 'Kullanici';
DELETE FROM customer WHERE last_name = 'Kullanici';

-- Audit loglarını görüntüle
SELECT id, tablo_adi, islem, kullanici, islem_zamani
FROM audit_log
ORDER BY islem_zamani DESC;
-- Sonuç: INSERT, UPDATE, DELETE hepsi kayıt altında!


-- ============================================================
-- ÖZET RAPOR
-- ============================================================

SELECT * FROM (VALUES
    ('Tanımlı rol sayısı',    (SELECT COUNT(*) FROM pg_roles WHERE rolname LIKE '%_role')::TEXT),
    ('Şifreli müşteri kaydı', (SELECT COUNT(*) FROM customer WHERE email_encrypted IS NOT NULL)::TEXT),
    ('Audit log kaydı',       (SELECT COUNT(*) FROM audit_log)::TEXT),
    ('Aktif trigger sayısı',  (SELECT COUNT(*) FROM information_schema.triggers
                               WHERE trigger_schema = 'public')::TEXT)
) AS rapor(baslik, deger);
