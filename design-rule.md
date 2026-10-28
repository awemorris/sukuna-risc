# Sukuna-RISC 設計ルール (design-rule.md)

本ドキュメントは、Sukuna-RISC の RTL 記述における統一規約、メモリマクロ・演算器の抽象化ルール、および FPGA/ASIC 両対応のための設計原則を定めます。

---

## 1. 目的と基本方針

1. **FPGA/ASIC のポータビリティ確保**:
   - 各社 FPGA（AMD/Xilinx, Intel, Lattice 等）のベンダー固有プリミティブや推論挙動の差異を吸収する。
   - ASIC 化の際、SRAM コンパイラやカスタムデータパスセルへの置換を容易にする。
2. **タイミングとレイテンシの明確化**:
   - 非同期読み出し可能なメモリとパイプライン同期読み出しメモリを厳密に区別し、意図しない合成結果（分散RAMの過剰消費やクリティカルパスの悪化）を防止する。

---

## 2. メモリ・レジスタ配列の記述ルール (厳格規約)

### 2.1 禁止事項
- **128ビットを超えるレジスタ**、および **すべての配列レジスタ (`reg [W-1:0] mem [0:D-1];`)** は、**直接 `reg` 構文で宣言・推論させてはならない**。
- 必ず `rtl/library/` 配下に用意された種別明示型 RAM モジュールをインスタンス化して使用すること。

### 2.2 メモリ種別とタイミング特性

| メモリ種別 | 抽象化モジュール | 読み出しタイミング | 推奨用途 | FPGA実装対象 | ASIC実装対象 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **BRAM** | `sk_ram_bram` | **同期（1〜2サイクル・パイプライン）**<br>※非同期読み出し不可 | L1I/L1D キャッシュデータ・タグアレイ、L2キャッシュ | Block RAM / UltraRAM | SRAM マクロ (SP/DP SRAM) |
| **Distributed RAM** | `sk_ram_dist` | **同期（1サイクル）**<br>※非同期読み出し不可 | TLB (L1/L2-TLB)、BPU (BTB/BHT)、キュー/FIFO | LUT RAM (SLICEM) | レジスタファイルセル / ラッチアレイ |
| **FF RAM** | `sk_ram_ff` | **非同期（0サイクル・組合せ回路）**<br>※同サイクルでデータ出力 | GPR (汎用レジスタファイル)、多ポート同期バッファ | フリップフロップ (FF / DFF) | スタンダードセル DFF アレイ |

> [!IMPORTANT]
> **BRAM および Distributed RAM はパイプライン化されており、非同期（クロック非同期のコンビネーショナル）での読み出しはできません。**
> 1サイクル内でアドレスを与えて即座にデータを取り出したい場合は、明示的に `sk_ram_ff` を使用するか、パイプライン段を再設計して同期読み出しに適合させてください。

### 2.3 128ビット以下レジスタの推論制御ディレクティブ (厳格定義)
128ビット以下のスカラ・ベクトルレジスタ（`reg [...] my_reg_q;`）は、意図しない Block RAM やシフトレジスタ (SRL16/SRL32) への推論を禁止し、必ず個別フリップフロップ (FF) として合成させるため、**行末に以下の共通ブロックコメント形式のディレクティブを付与**します。

#### 統一ディレクティブ文字列:
```verilog
/* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
```

- **記述例**:
  ```verilog
  reg [XLEN-1:0] pc_q;       /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg [31:0]     inst_q;     /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  reg            valid_q;    /* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" */
  ```
- **Vivado / Synplify での解釈**:
  - `syn_ramstyle = "registers"`: BRAM / LUTRAM へのマッピングを禁止し、D-FF に強制。
  - `syn_srlstyle = "registers"`: シフトレジスタ (SRL) へのマッピングを禁止し、D-FF に強制。
- **Synopsys (Design Compiler) 用置換スクリプト**:
  ASIC 向けフロー等で Synopsys 形式のディレクティブに変換する場合、以下の `sed` コマンドで一括リプレース可能です。
  ```bash
  sed -i 's|/\* synthesis syn_ramstyle = "registers", syn_srlstyle = "registers" \*/|/* synopsys preserve_sequential */|g' rtl/**/*.v
  ```

---

## 3. 演算器・データパスセルの抽象化ルール

乗算器、除算器、加減算器、積和演算器、シフタなどの演算器は、ターゲット環境によって FPGA の DSP スライス（DSP48E2等）や ASIC のデータパスジェネレータ（DW / Synopsys DesignWare等）に置換できるよう、`rtl/library/` の抽象化セルを使用します。

### 抽象化セル一覧
- `sk_add`: 加算器 (Adder, パラメータ `IMPL = "CARRY" / "LOGIC" / "DSP"`)
- `sk_sub`: 減算器 (Subtractor, パラメータ `IMPL = "CARRY" / "LOGIC" / "DSP"`)
- `sk_addsub`: 加減算器 (Add/Sub 切り替え, パラメータ `IMPL = "CARRY" / "LOGIC" / "DSP"`)
- `sk_mul`: 乗算器 (DSP Multiplier, パラメータ `IMPL = "DSP" / "CARRY" / "LOGIC"`, パイプライン化可能)
- `sk_div`: 除算器 (Divider, パラメータ `IMPL = "CARRY" / "LOGIC" / "DSP"`)
- `sk_fma`: 積和演算器 (Fused Multiply-Add: `A * B + C`, パラメータ `IMPL = "DSP" / "CARRY" / "LOGIC"`)
- `sk_shift`: シフタ (Barrel Shifter: SLL, SRL, SRA)
- `sk_msb`: MSB検出 / Leading Zero Counter (CLZ / Priority Encoder)

### 3.1 演算器の実装指定パラメータ (`IMPL`)
各演算モジュールは `parameter IMPL` により生成されるハードウェア構造を明示的に指定可能：
- `"DSP"`: ハードウェアDSPスライス（`DSP48E1` 直接生成または属性 `(* use_dsp = "yes" *)`）
- `"CARRY"`: スライス内専用キャリーチェーン（`CARRY4` による高速加減算）
- `"LOGIC"`: 純粋な汎用LUTロジックゲート（DSP/キャリーチェーンを使わない合成）

---

## 4. コーディング規約 (Verilog 2005)

1. **言語規格**:
   - **Verilog 2005 (IEEE 1364-2005)** に準拠すること。
   - ANSI C スタイルのポート宣言（モジュールヘッダ内での `input wire ...` / `output reg ...`）を使用する。
2. **クロックとリセット**:
   - リセットは原則として **非同期アクティブロー (`rst_ni`)** を標準とする。
   - モジュール名末尾:
     - `_i`: 入力ポート
     - `_o`: 出力ポート
     - `_q`: レジスタ出力
     - `_d`: 次状態コンビネーショナル信号
3. **幅と定数**:
   - ベクトル幅および数値リテラルは常にビット幅を明示する（例: `32'd0`, `64'h80000000`）。
   - 共通パラメータは `sukuna_defines.vh` をインクルードして参照する。
