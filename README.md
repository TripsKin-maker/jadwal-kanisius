# Jadwal Kanisius — akun admin dan siswa per kelas

Website: **https://tripskin-maker.github.io/jadwal-kanisius/**

Versi ini memakai akun yang sudah dibuat otomatis. Siswa tidak perlu mendaftar atau membuat akun sendiri.

## Akun yang tersedia

Terdapat 24 kelas:

- X-1 sampai X-8
- XI-1 sampai XI-8
- XII-1 sampai XII-8

Setiap kelas memiliki:

- 1 akun admin kelas
- 40 akun siswa (`siswa01` sampai `siswa40`)

Total: **24 admin + 960 siswa = 984 akun**.

### Pola akun siswa

Untuk kelas X-1, siswa nomor 01:

- Username: `X1-siswa01`
- Password: `Siswa01!X1`

Untuk kelas XI-4, siswa nomor 23:

- Username: `XI4-siswa23`
- Password: `Siswa23!XI4`

Untuk kelas XII-8, siswa nomor 40:

- Username: `XII8-siswa40`
- Password: `Siswa40!XII8`

### Pola akun admin

Untuk kelas X-1:

- Username: `adminX1`
- Password: `AdminX1!`

Untuk kelas XI-4:

- Username: `adminXI4`
- Password: `AdminXI4!`

Untuk kelas XII-8:

- Username: `adminXII8`
- Password: `AdminXII8!`

Username tidak membedakan huruf besar/kecil, tetapi password harus ditulis persis.

## Hak akses

### Admin kelas

- Hanya melihat kelasnya sendiri.
- Dapat menambah, mengedit, dan menghapus Tugas/PR serta Ulangan.
- Tidak memiliki kotak centang selesai.

### Siswa

- Hanya melihat kelasnya sendiri.
- Tidak dapat menambah, mengedit, atau menghapus tugas dan ulangan.
- Dapat mencentang selesai/belum selesai.
- Status selesai bersifat pribadi per akun siswa dan tidak mengubah status siswa lain.

## Pengaturan Supabase satu kali

1. Buka proyek Supabase yang URL dan publishable key-nya sudah terpasang di `index.html`.
2. Pilih **SQL Editor → New query**.
3. Tempel seluruh isi `supabase-setup.sql` lalu tekan **Run**.
4. Hasil paling bawah harus menunjukkan `24` akun admin dan `960` akun student.

SQL menyimpan password sebagai hash bcrypt. Tabel akun, sesi, tugas, dan penyelesaian tidak dapat dibaca langsung menggunakan browser key; aplikasi hanya dapat memakai RPC yang memvalidasi sesi dan peran.

> Karena password awal mengikuti pola yang mudah ditebak, sebaiknya admin dan siswa mengganti password setelah login jika website akan dipakai untuk data sungguhan.

## Publikasi GitHub Pages

Repository menggunakan `.github/workflows/pages.yml`. Setiap perubahan yang didorong ke branch `main` akan dipublikasikan otomatis ke GitHub Pages.
