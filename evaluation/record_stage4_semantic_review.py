"""Serialize the developer's manual reading of original reports, not an auto-grader."""
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "agent"))
from bailian_client import read_json, sha256


def main():
    base = ROOT / "results/EXP-20261020-020"
    audit = read_json(base / "evaluation/deterministic_audit.json")
    rubric_path = ROOT / "data/evaluation_private/EXP-20261020-019/rubric.json"
    rubric = read_json(rubric_path)
    # These judgments were made by reading the unchanged original text and actual
    # returned summaries. The code only binds exact quotations and serializes them.
    judgments = [
        {
            "core_assessment": "电流和、转矩双报警及位置未报警正确；保留共享电流导致交叉响应、相别不可唯一定位及不能确认双故障。",
            "support_fields": ["finding", "candidate_assessment", "candidates", "time_interpretation"],
            "physical_explanation": "needs_revision", "information_boundary": "passed",
            "whole_original_text_accepted": False,
            "issues": [{"category": "temporal_summary", "field": "candidate_assessment",
                "quote": "转矩（按规定指令补偿）在有效段末端短时越限",
                "assessment": "时间概括不完整：第二有效段开始处也报警。原文列出的0.522 s数值正确，但不支持把所有短时异常概括为末端。",
                "actual_evidence": "locate_anomalies: torque alarm_intervals_s=[0.210,0.216],[0.522,0.532],[0.710,0.716]; second valid interval=[0.513,0.716].",
                "research_correction_only": "第一段末端及第二段开始、末端有短时报警；不向模型反馈或重跑。"}],
            "notes": ["0.038 N*m约为阈值47倍；原文称幅值较小仅能理解为相对量级，不能理解为不显著或不报警。"]
        },
        {
            "core_assessment": "转矩持续报警及两段时间正确，负载/补偿、参数和共享电流候选有保留；没有把等效阻力解释为真实润滑退化，也未复现阶段3的共模不敏感错误。",
            "support_fields": ["finding", "candidate_assessment", "candidates", "no_alarm_interpretation"],
            "physical_explanation": "passed_with_wording_note", "information_boundary": "passed",
            "whole_original_text_accepted": True,
            "issues": [],
            "notes": ["‘共同偏差以外的相间偏差不被三相和检出’应限定为三相误差和为零的抵消分量，不能泛指任意相间偏差。结合其余段落的抵消型限定，本次记措辞提醒，不另判必需点失败。",
                      "未把附加机械阻力单独列为候选；正常外载差异/补偿误差及机械参数项已保留，满足冻结条目中的‘等有依据候选’，不事后要求必须枚举每个名称。"]
        },
        {
            "core_assessment": "三通道无报警，407点及本例分段正确；明确初值相减抵消初始恒定偏置，没有凭盲区确认案例有偏置，也未以无报警证明绝对健康。",
            "support_fields": ["finding", "candidate_assessment", "channels", "assumptions", "no_alarm_interpretation"],
            "physical_explanation": "passed", "information_boundary": "passed",
            "whole_original_text_accepted": True, "issues": [],
            "notes": ["额外计算prescribed_command并定位，总工具8次；两种模式幅值相同，本例无需比较但允许执行，不构成新增物理样本。",
                      "候选列表为空适合当前未检出的结论，不能因此认定为过度保留；方法盲区及需要的独立参考已解释。"]
        },
        {
            "core_assessment": "位置新增相对不一致、位置和速度侧候选、初始偏置抵消及报警非起点解释正确。",
            "support_fields": ["finding", "candidate_assessment", "candidates", "channels", "time_interpretation"],
            "physical_explanation": "needs_revision", "information_boundary": "needs_revision_for_trend_claim",
            "whole_original_text_accepted": False,
            "issues": [{"category": "unsupported_temporal_strengthening", "field": "candidates[1].basis",
                "quote": "残差在有效运动段内持续同向",
                "assessment": "实际返回全有效段的均值、RMS、最大绝对值及绝对阈值报警区间，不能由此证明各时刻持续同向；模型未取得逐点残差或图像像素。正均值说明净正向平均偏移，不等于逐点方向证据。",
                "actual_evidence": "compute_residual_bundle: valid_mean=1.547e-05 m, valid_max_abs=2.006e-05 m; locate_anomalies uses absolute threshold; plot_evidence returns references, not image pixels.",
                "research_correction_only": "已返回的平均残差为正，且两段出现持续绝对越限；逐点符号和精确增长曲线需要额外可见证据。"}],
            "notes": ["不借私有linear_ramp标签补全或替模型证明单调增长；即使原始波形恰好相容，也不能追认未向模型提供的证据。"]
        },
        {
            "core_assessment": "1500 N主分析0.029 s转矩报警与1800 N同观测比较正确；保留原BUNDLE，比较后最大残差0.000694 N*m且三通道未报警，未将指令当独立测量或确诊机械故障。",
            "support_fields": ["finding", "candidate_assessment", "candidates", "assumptions", "unknowns"],
            "physical_explanation": "needs_revision", "information_boundary": "passed",
            "whole_original_text_accepted": False,
            "issues": [{"category": "physical_explanation", "field": "candidates[1].caveat",
                "quote": "无法排除单相偏置等抵消型干扰",
                "assessment": "单独一相增加非零偏置b、其余不变时三相和增加b，并非抵消型。低于当前阈值的单相偏差可能未检出，但这是幅值/检测边界，不能与三相误差和为零的抵消混称。",
                "actual_evidence": "phase sum identity: delta(ia+ib+ic)=delta_ia+delta_ib+delta_ic; a single nonzero offset does not cancel.",
                "research_correction_only": "可保留三相误差和近零的抵消型偏差、低于当前检出限的偏差或其他未检验干扰；不能把单相偏置称为抵消型。"}],
            "notes": ["1800 N与1500 N之差300 N已通过两值及补偿效果解释；不因未额外写出‘300’这个字符串而事后判必需条目缺失。",
                      "该错误不改变负载比较的主要结果，但全文不能称完全正确。"]
        },
    ]
    reviews = []
    for result, judgment, reference in zip(audit["tasks"], judgments, rubric["tasks"]):
        assert result["task_id"] == reference["task_id"]
        folder = ROOT / result["run_directory"]
        report = read_json(folder / "report.json")
        text = (folder / "final_response.md").read_text(encoding="utf-8")
        for issue in judgment["issues"]:
            # Ensure every criticism is tied to unchanged exact original wording.
            assert issue["quote"] in text
        fields = {key: report[key] for key in judgment["support_fields"]}
        row = {"task_id": result["task_id"], "case_id": result["case_id"],
            "source_final_sha256": sha256(folder / "final_response.md"),
            "original_report_repairs": result["report_repairs"],
            "frozen_mandatory_points": [{"requirement": claim, "coverage": "covered_in_original",
                "basis": "Manual reading of the source fields below; coverage is not a certification that all surrounding prose is correct."}
                for claim in reference["required_claims"]],
            "explicit_forbidden_claims": [{"claim": claim, "found": False} for claim in reference["forbidden_claims"]],
            "original_support_fields": fields, **judgment}
        reviews.append(row)
    out = {"experiment_id": "EXP-20261020-020", "reviewed_at_utc": datetime.now(timezone.utc).isoformat(),
        "reviewer": "Research-side developer manual review by the same coding assistant; not independent or blinded.",
        "private_frozen_rubric_sha256": sha256(rubric_path),
        "scoring_interpretation": "Frozen necessary-claim coverage and explicit forbidden claims are recorded separately. Full-text acceptance additionally records actual contradictory/unsupported explanations within the frozen physical-explanation and information-boundary dimensions. The specific wording issues were identified after execution, are not newly preregistered performance metrics, and do not replace the frozen rubric or numerical scores.",
        "tasks": reviews,
        "mandatory_point_coverage_tasks": 5,
        "explicit_frozen_forbidden_claim_detected_tasks": 0,
        "full_original_text_accepted_tasks": sum(r["whole_original_text_accepted"] for r in reviews),
        "original_text_requires_revision_tasks": sum(not r["whole_original_text_accepted"] for r in reviews),
        "overconfirmed_unique_fault_tasks": 0, "unsupported_absolute_health_tasks": 0,
        "unnecessary_abstention_detected_tasks": 0,
        "formal_generalization_accuracy": None,
        "no_model_feedback_or_reruns": True}
    private_out = ROOT / "data/evaluation_private/EXP-20261020-020/semantic_review.json"
    private_out.parent.mkdir(parents=True, exist_ok=True)
    private_out.write_text(json.dumps(out, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({k: out[k] for k in ("mandatory_point_coverage_tasks", "full_original_text_accepted_tasks", "original_text_requires_revision_tasks")}))


if __name__ == "__main__":
    main()
