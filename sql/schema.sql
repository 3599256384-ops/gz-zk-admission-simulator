-- =====================================================================
-- 广州中考公办高中录取模拟系统 建表脚本（MySQL 8, utf8mb4）
--
-- 【契约文件】改表必须先改本文件与 docs/02-数据库设计.md，再通知全组，
--   禁止只在自己本地改表结构。
-- 执行方式：
--   CREATE DATABASE zk_admission DEFAULT CHARACTER SET utf8mb4;
--   mysql -u root -p zk_admission < sql/schema.sql
--
-- 设计说明（教学注释）：
--   1. 每个表都有自增物理主键 id，业务上另设逻辑唯一键（如 school_no），
--      这样业务编号可以人工修改，不影响外键引用。
--   2. 所有批次相关枚举（batch/category）用 CHECK 约束卡范围，
--      从数据库层面挡住非法输入，配合应用层校验 V1~V10 双重保险。
--   3. admission_record 上加了 (run_id, student_id) 唯一键，
--      直接保证系统约束①“每名考生每次模拟最多录取一次”不可能被违反。
--   4. 分数列用 SMALLINT（-32768~32767），广州中考满分 810，够用且省空间；
--      名额/序号用 INT；人数规模大的列注意索引（见各表 KEY）。
-- =====================================================================

SET NAMES utf8mb4;

-- ---------------------------------------------------------------------
-- 1. 初中：名额分配中“生源学校”的一方
-- ---------------------------------------------------------------------
CREATE TABLE junior_school (
    id        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    school_no VARCHAR(32)     NOT NULL                COMMENT '学校编号（业务唯一，可人工指定，如 J001）',
    name      VARCHAR(128)    NOT NULL                COMMENT '学校名称',
    PRIMARY KEY (id),
    UNIQUE KEY uk_junior_no (school_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='初中';

-- ---------------------------------------------------------------------
-- 2. 高中：招生学校的一方
--    school_type: demonstration=示范性（第三批统招） non_demonstration=非示范（第四批统招）
--    unified_batch 与 school_type 一一对应，二选一设置；任务书要求
--    “每所高中只在第三或第四批之一设置统招接收计划”。
-- ---------------------------------------------------------------------
CREATE TABLE high_school (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    school_no        VARCHAR(32)     NOT NULL                COMMENT '学校编号（业务唯一，如 H001）',
    name             VARCHAR(128)    NOT NULL                COMMENT '学校名称',
    school_type      ENUM('demonstration','non_demonstration') NOT NULL COMMENT '示范性/非示范',
    unified_batch    ENUM('third','fourth') NOT NULL         COMMENT '统招接收批次：third=第三批 fourth=第四批',
    has_self_enroll  TINYINT(1)      NOT NULL DEFAULT 0      COMMENT '是否有第一批自主招生资格（1=有）',
    has_quota_alloc  TINYINT(1)      NOT NULL DEFAULT 0      COMMENT '是否有第二批名额分配（1=有）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_high_no (school_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='高中（公办普通高中）';

-- ---------------------------------------------------------------------
-- 3. 考生
--    (total_score, tie_break_no) 联合唯一 = 校验项 V3：
--    “同一总分内同分序号唯一”，数据库层面直接卡死。
-- ---------------------------------------------------------------------
CREATE TABLE student (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    student_no       VARCHAR(32)     NOT NULL                COMMENT '考生编号（业务唯一，如 S0001）',
    name             VARCHAR(64)     NOT NULL                COMMENT '虚构姓名',
    junior_school_id BIGINT UNSIGNED NOT NULL                COMMENT '所属初中（决定第二批名额分配竞争范围）',
    total_score      SMALLINT        NOT NULL                COMMENT '中考总分（0~810 可配置），即投档分',
    tie_break_no     INT             NOT NULL                COMMENT '同分序号：同一总分内唯一，越小越优先',
    PRIMARY KEY (id),
    UNIQUE KEY uk_student_no (student_no),
    UNIQUE KEY uk_score_tie (total_score, tie_break_no),
    KEY idx_junior (junior_school_id),
    CONSTRAINT fk_student_junior FOREIGN KEY (junior_school_id)
        REFERENCES junior_school (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='考生';

-- ---------------------------------------------------------------------
-- 4. 招生计划（主计划）
--    batch: 1=自主招生 2=名额分配 3=第三批统招 4=第四批统招
--    category 与 batch 存在对应关系，用 CHECK 卡住，防止录入张冠李戴。
--    control_line: 计划控制线，必须 >= L（校验 V7，应用层校验）。
-- ---------------------------------------------------------------------
CREATE TABLE plan (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    year          SMALLINT        NOT NULL                COMMENT '模拟年度，如 2026',
    high_school_id BIGINT UNSIGNED NOT NULL               COMMENT '所属高中',
    batch         TINYINT         NOT NULL                COMMENT '批次：1/2/3/4',
    category      ENUM('self_enroll','quota_alloc','unified_third','unified_fourth') NOT NULL COMMENT '计划类别',
    initial_quota INT             NOT NULL                COMMENT '初始名额（人数）',
    control_line  SMALLINT        NOT NULL DEFAULT 0      COMMENT '计划控制线，0 表示不设（取全局 L）',
    is_active     TINYINT(1)      NOT NULL DEFAULT 1      COMMENT '是否启用（1=启用；停用后校验 V5 会拦截）',
    PRIMARY KEY (id),
    KEY idx_plan_hs_batch (high_school_id, batch),
    CONSTRAINT fk_plan_hs FOREIGN KEY (high_school_id)
        REFERENCES high_school (id),
    CONSTRAINT chk_plan_batch CHECK (batch BETWEEN 1 AND 4),
    CONSTRAINT chk_plan_cat CHECK (
        (batch = 1 AND category = 'self_enroll')    OR
        (batch = 2 AND category = 'quota_alloc')    OR
        (batch = 3 AND category = 'unified_third')  OR
        (batch = 4 AND category = 'unified_fourth')
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='招生计划（总计划按规则切分后的各批次计划）';

-- ---------------------------------------------------------------------
-- 5. 名额分配子计划：plan × junior_school 的明细名额
--    第二批投档的最小竞争单元就是一行 plan_quota。
--    校验 V6：同一 plan 下各初中名额之和不得超过该计划初始名额。
-- ---------------------------------------------------------------------
CREATE TABLE plan_quota (
    id               BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    plan_id          BIGINT UNSIGNED NOT NULL                COMMENT '名额分配主计划',
    junior_school_id BIGINT UNSIGNED NOT NULL                COMMENT '获得名额的初中',
    quota            INT             NOT NULL                COMMENT '该初中获得的名额数',
    PRIMARY KEY (id),
    UNIQUE KEY uk_plan_junior (plan_id, junior_school_id),
    KEY idx_quota_junior (junior_school_id),
    CONSTRAINT fk_pq_plan FOREIGN KEY (plan_id)
        REFERENCES plan (id),
    CONSTRAINT fk_pq_junior FOREIGN KEY (junior_school_id)
        REFERENCES junior_school (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='名额分配子计划（高中分给各初中的名额）';

-- ---------------------------------------------------------------------
-- 6. 自主招生资格
--    rank_no 在同一高中内唯一（校验 V8），越小越优先。
-- ---------------------------------------------------------------------
CREATE TABLE self_enroll_qualification (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    year          SMALLINT        NOT NULL                COMMENT '年度',
    student_id    BIGINT UNSIGNED NOT NULL                COMMENT '考生',
    high_school_id BIGINT UNSIGNED NOT NULL               COMMENT '获得资格的高中',
    status        ENUM('qualified','not_qualified') NOT NULL DEFAULT 'qualified' COMMENT '资格状态',
    rank_no       INT             NOT NULL                COMMENT '考核排名（校内唯一，升序录取）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_qual_rank (year, high_school_id, rank_no),
    UNIQUE KEY uk_qual_stu (year, student_id, high_school_id),
    CONSTRAINT fk_qual_student FOREIGN KEY (student_id)
        REFERENCES student (id),
    CONSTRAINT fk_qual_hs FOREIGN KEY (high_school_id)
        REFERENCES high_school (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='自主招生资格与考核排名';

-- ---------------------------------------------------------------------
-- 7. 志愿
--    校验 V4：同一批次内同一高中不能重复填报 → 唯一键直接卡死。
--    志愿序号上限：第一批 1、第二批 3、第三四批 6，用 CHECK 卡范围。
-- ---------------------------------------------------------------------
CREATE TABLE volunteer (
    id            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    year          SMALLINT        NOT NULL                COMMENT '年度',
    student_id    BIGINT UNSIGNED NOT NULL                COMMENT '考生',
    batch         TINYINT         NOT NULL                COMMENT '批次：1/2/3/4',
    seq           TINYINT         NOT NULL                COMMENT '志愿序号（从 1 开始）',
    high_school_id BIGINT UNSIGNED NOT NULL               COMMENT '目标高中',
    PRIMARY KEY (id),
    UNIQUE KEY uk_vol_seq (year, student_id, batch, seq),
    UNIQUE KEY uk_vol_hs  (year, student_id, batch, high_school_id),
    CONSTRAINT fk_vol_student FOREIGN KEY (student_id)
        REFERENCES student (id),
    CONSTRAINT fk_vol_hs FOREIGN KEY (high_school_id)
        REFERENCES high_school (id),
    CONSTRAINT chk_vol_batch CHECK (batch BETWEEN 1 AND 4),
    CONSTRAINT chk_vol_seq CHECK (
        (batch = 1 AND seq = 1) OR
        (batch = 2 AND seq BETWEEN 1 AND 3) OR
        (batch IN (3,4) AND seq BETWEEN 1 AND 6)
    )
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='志愿表';

-- ---------------------------------------------------------------------
-- 8. 模拟运行（快照头）
--    规则参数 + 数据版本号都落库，支撑 T12“同一快照结果一致”。
--    已完成（done）的运行，其输入数据版本不允许被静默修改（应用层锁定）。
-- ---------------------------------------------------------------------
CREATE TABLE sim_run (
    id           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    run_no       VARCHAR(64)     NOT NULL                COMMENT '运行编号（业务唯一，如 R2026-001）',
    year         SMALLINT        NOT NULL                COMMENT '模拟年度',
    L            SMALLINT        NOT NULL                COMMENT '最低控制线',
    G1           SMALLINT        NOT NULL                COMMENT '第一梯度线',
    delta        SMALLINT        NOT NULL                COMMENT '梯度间隔，默认 40',
    data_version VARCHAR(64)     NOT NULL                COMMENT '输入数据版本号（快照依据）',
    status       ENUM('checking','running','done','failed') NOT NULL DEFAULT 'checking' COMMENT '运行状态',
    started_at   DATETIME        NULL                    COMMENT '开始时间',
    finished_at  DATETIME        NULL                    COMMENT '结束时间',
    remark       VARCHAR(255)    NULL                    COMMENT '备注（如：滑档案例A）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_run_no (run_no)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='模拟运行记录（快照头）';

-- ---------------------------------------------------------------------
-- 9. 计划账本（每次运行的每计划余额）
--    transferred_in/out 记录结转流水影响；admitted/remaining 记录结果。
--    校验约束④：initial + in - out = admitted + remaining。
--    前端“录取进度/计划余额”页面直接查这张表。
-- ---------------------------------------------------------------------
CREATE TABLE plan_state (
    id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    run_id          BIGINT UNSIGNED NOT NULL                COMMENT '所属运行',
    plan_id         BIGINT UNSIGNED NOT NULL                COMMENT '计划',
    initial_quota   INT             NOT NULL                COMMENT '初始名额',
    transferred_in  INT             NOT NULL DEFAULT 0      COMMENT '转入名额（结转增加）',
    transferred_out INT             NOT NULL DEFAULT 0      COMMENT '转出名额（结转减少）',
    admitted        INT             NOT NULL DEFAULT 0      COMMENT '已录取人数',
    remaining       INT             NOT NULL DEFAULT 0      COMMENT '剩余名额',
    PRIMARY KEY (id),
    UNIQUE KEY uk_state_run_plan (run_id, plan_id),
    KEY idx_state_plan (plan_id),
    CONSTRAINT fk_state_run FOREIGN KEY (run_id)
        REFERENCES sim_run (id),
    CONSTRAINT fk_state_plan FOREIGN KEY (plan_id)
        REFERENCES plan (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='计划账本（每次运行的计划余额快照）';

-- ---------------------------------------------------------------------
-- 10. 录取结果
--     admit_seq：投档顺序号（按录取发生的先后），末位考生 = 该计划
--     admit_seq 最大的记录；最低录取分 = 该计划 total_score 的最小值。
--     (run_id, student_id) 唯一 = 系统约束①。
-- ---------------------------------------------------------------------
CREATE TABLE admission_record (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    run_id         BIGINT UNSIGNED NOT NULL                COMMENT '所属运行',
    student_id     BIGINT UNSIGNED NOT NULL                COMMENT '考生',
    high_school_id BIGINT UNSIGNED NOT NULL                COMMENT '录取高中',
    plan_id        BIGINT UNSIGNED NOT NULL                COMMENT '录取计划',
    volunteer_id   BIGINT UNSIGNED NOT NULL                COMMENT '对应志愿（约束③：录取必须对应有效志愿）',
    batch          TINYINT         NOT NULL                COMMENT '录取批次',
    volunteer_seq  TINYINT         NOT NULL                COMMENT '录取所用志愿序号',
    admit_seq      INT             NOT NULL                COMMENT '投档顺序号（录取先后顺序，全运行内递增）',
    total_score    SMALLINT        NOT NULL                COMMENT '考生总分（冗余存储，便于统计）',
    tie_break_no   INT             NOT NULL                COMMENT '同分序号（冗余存储）',
    PRIMARY KEY (id),
    UNIQUE KEY uk_admit_run_stu (run_id, student_id),
    KEY idx_admit_run_plan (run_id, plan_id),
    KEY idx_admit_run_hs (run_id, high_school_id),
    CONSTRAINT fk_admit_run FOREIGN KEY (run_id)
        REFERENCES sim_run (id),
    CONSTRAINT fk_admit_student FOREIGN KEY (student_id)
        REFERENCES student (id),
    CONSTRAINT fk_admit_hs FOREIGN KEY (high_school_id)
        REFERENCES high_school (id),
    CONSTRAINT fk_admit_plan FOREIGN KEY (plan_id)
        REFERENCES plan (id),
    CONSTRAINT fk_admit_vol FOREIGN KEY (volunteer_id)
        REFERENCES volunteer (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='录取结果（每次运行一份）';

-- ---------------------------------------------------------------------
-- 11. 结转流水
--     from_junior_school_id：名额分配剩余从具体初中汇总转出时记录来源初中；
--     自主招生结转时为 NULL。每次运行每个来源计划只允许出现一条（应用层保证）。
-- ---------------------------------------------------------------------
CREATE TABLE transfer_log (
    id                   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    run_id               BIGINT UNSIGNED NOT NULL                COMMENT '所属运行',
    from_plan_id         BIGINT UNSIGNED NOT NULL                COMMENT '来源计划（第一/二批计划）',
    from_batch           TINYINT         NOT NULL                COMMENT '来源批次：1 或 2',
    from_junior_school_id BIGINT UNSIGNED NULL                  COMMENT '来源初中（第二批名额分配结转时记录）',
    to_plan_id           BIGINT UNSIGNED NOT NULL                COMMENT '去向计划（本校第三批统招计划）',
    quota                INT             NOT NULL                COMMENT '结转名额数',
    created_at           DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '结转时点',
    remark               VARCHAR(255)    NULL                    COMMENT '备注',
    PRIMARY KEY (id),
    KEY idx_tl_run (run_id),
    CONSTRAINT fk_tl_run FOREIGN KEY (run_id)
        REFERENCES sim_run (id),
    CONSTRAINT fk_tl_from_plan FOREIGN KEY (from_plan_id)
        REFERENCES plan (id),
    CONSTRAINT fk_tl_to_plan FOREIGN KEY (to_plan_id)
        REFERENCES plan (id),
    CONSTRAINT fk_tl_from_junior FOREIGN KEY (from_junior_school_id)
        REFERENCES junior_school (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='结转流水（名额来源与去向）';

-- ---------------------------------------------------------------------
-- 12. 跳过日志（投档日志）
--     记录“为什么这个考生在这个志愿上没有被录取”，支撑结果查询功能
--     “解释未录取原因”。balance_at 是当时该计划剩余名额，用于回溯。
-- ---------------------------------------------------------------------
CREATE TABLE skip_log (
    id             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '物理主键',
    run_id         BIGINT UNSIGNED NOT NULL                COMMENT '所属运行',
    student_id     BIGINT UNSIGNED NOT NULL                COMMENT '考生',
    plan_id        BIGINT UNSIGNED NULL                    COMMENT '涉及计划（未填报时可为空）',
    volunteer_id   BIGINT UNSIGNED NULL                    COMMENT '涉及志愿（未填报时可为空）',
    batch          TINYINT         NOT NULL                COMMENT '批次',
    volunteer_seq  TINYINT         NOT NULL                COMMENT '志愿序号',
    reason         ENUM('BELOW_L','BELOW_PLAN_LINE','NOT_QUALIFIED','QUOTA_FULL','ALREADY_ADMITTED','NOT_APPLIED') NOT NULL COMMENT '跳过原因编码',
    balance_at     INT             NULL                    COMMENT '当时该计划剩余名额',
    created_at     DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '记录时点',
    PRIMARY KEY (id),
    KEY idx_sl_run_stu (run_id, student_id),
    KEY idx_sl_run_plan (run_id, plan_id),
    CONSTRAINT fk_sl_run FOREIGN KEY (run_id)
        REFERENCES sim_run (id),
    CONSTRAINT fk_sl_student FOREIGN KEY (student_id)
        REFERENCES student (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='投档日志（录取或跳过理由、当时余额）';
