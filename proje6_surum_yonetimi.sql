-- ============================================================
-- BLM4522 - Proje 6: Veritabanı Yükseltme ve Sürüm Yönetimi
-- Veritabanı: DVDRental (PostgreSQL 17)
-- ============================================================

-- TEMİZLİK
DROP TABLE IF EXISTS schema_degisiklik_log;
DROP TABLE IF EXISTS geri_donus_log;
DROP FUNCTION IF EXISTS ddl_trigger_func();
DROP FUNCTION IF EXISTS geri_donus_trigger_func();
DROP EVENT TRIGGER IF EXISTS trg_ddl_takip;

-- ============================================================
-- BÖLÜM 0: MEVCUT VERİTABANI SÜRÜM BİLGİSİ
-- ============================================================

SELECT version() AS postgresql_surumu;

SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position
LIMIT 20;
-- Sonuç: Mevcut şema yapısı belgelendi

-- ============================================================
-- BÖLÜM 1: VERİTABANI YÜKSELTİME PLANI
-- ============================================================

-- Yükseltme öncesi mevcut nesneleri kayıt altına al
SELECT * FROM (VALUES
    ('Tablo sayısı',    (SELECT COUNT(*) FROM information_schema.tables
                         WHERE table_schema = 'public')::TEXT),
    ('View sayısı',     (SELECT COUNT(*) FROM information_schema.views
                         WHERE table_schema = 'public')::TEXT),
    ('Fonksiyon sayısı',(SELECT COUNT(*) FROM information_schema.routines
                         WHERE routine_schema = 'public')::TEXT),
    ('İndeks sayısı',   (SELECT COUNT(*) FROM pg_indexes
                         WHERE schemaname = 'public')::TEXT)
) AS plan(nesne, adet);

-- ============================================================
-- BÖLÜM 2: SÜRÜM YÖNETİMİ (DDL Trigger)
-- ============================================================

-- Şema değişikliklerini takip eden log tablosu
CREATE TABLE schema_degisiklik_log (
    id          SERIAL PRIMARY KEY,
    komut_turu  TEXT,
    nesne_turu  TEXT,
    nesne_adi   TEXT,
    kullanici   TEXT,
    degisim_zamani TIMESTAMPTZ DEFAULT NOW()
);

-- DDL trigger fonksiyonu
CREATE OR REPLACE FUNCTION ddl_trigger_func()
RETURNS event_trigger AS $$
DECLARE
    obj RECORD;
BEGIN
    FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands()
    LOOP
        INSERT INTO schema_degisiklik_log(komut_turu, nesne_turu, nesne_adi, kullanici)
        VALUES (obj.command_tag, obj.object_type, obj.object_identity, current_user);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Event trigger oluştur (tüm DDL komutlarını yakala)
CREATE EVENT TRIGGER trg_ddl_takip
    ON ddl_command_end
    EXECUTE FUNCTION ddl_trigger_func();

-- DDL trigger testi: yeni sütun ekle
ALTER TABLE film ADD COLUMN IF NOT EXISTS test_sutun TEXT;
ALTER TABLE film DROP COLUMN IF EXISTS test_sutun;

-- Şema değişikliklerini görüntüle
SELECT komut_turu, nesne_turu, nesne_adi, kullanici, degisim_zamani
FROM schema_degisiklik_log
ORDER BY degisim_zamani DESC;

-- ============================================================
-- BÖLÜM 3: TEST VE GERİ DÖNÜŞ PLANI
-- ============================================================

-- Geri dönüş için mevcut yapıyı snaphot olarak kaydet
CREATE TABLE geri_donus_log (
    id           SERIAL PRIMARY KEY,
    tablo_adi    TEXT,
    sutun_sayisi INT,
    kayit_zamani TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO geri_donus_log(tablo_adi, sutun_sayisi)
SELECT table_name,
       COUNT(column_name)
FROM information_schema.columns
WHERE table_schema = 'public'
GROUP BY table_name;

-- Geri dönüş planını doğrula
SELECT tablo_adi, sutun_sayisi, kayit_zamani
FROM geri_donus_log
ORDER BY tablo_adi;

-- ============================================================
-- ÖZET RAPOR
-- ============================================================

SELECT * FROM (VALUES
    ('DDL log kaydı',       (SELECT COUNT(*) FROM schema_degisiklik_log)::TEXT),
    ('Geri dönüş snapshot', (SELECT COUNT(*) FROM geri_donus_log)::TEXT),
    ('PostgreSQL sürümü',   (SELECT split_part(version(), ' ', 2)))
) AS rapor(baslik, deger);
