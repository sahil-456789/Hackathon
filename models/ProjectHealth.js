// models/ProjectHealth.js
import mongoose from "mongoose";

const riskFactorSchema = new mongoose.Schema({
  factor: { type: String, required: true },
  severity: { type: String, enum: ["Low", "Medium", "High"], required: true },
  impact: { type: String, required: true },
});

const projectHealthSchema = new mongoose.Schema(
  {
    projectHealth: {
      type: String,
      enum: ["GREEN", "YELLOW", "RED"],
      required: true,
    },
    score: { type: Number, min: 0, max: 100, required: true },
    metrics: {
      velocity: { type: Number, min: 0, max: 100, required: true },
      issueStatus: { type: String, required: true },
      riskFactors: [riskFactorSchema],
      recommendations: [{ type: String }],
    },
    analysis: { type: String },
  },
  { timestamps: true }
);

export default mongoose.model("ProjectHealth", projectHealthSchema);
