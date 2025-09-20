// controllers/projectHealthController.js
import asyncHandler from "express-async-handler";
import ProjectHealth from "../models/ProjectHealth.js";

// Create new report
export const createReport = asyncHandler(async (req, res) => {
  const report = new ProjectHealth(req.body);
  await report.save();
  res.status(201).json(report);
});

// Get all reports
export const getReports = asyncHandler(async (req, res) => {
  const reports = await ProjectHealth.find().sort({ createdAt: -1 });
  res.json(reports);
});

// Get single report by ID
export const getReportById = asyncHandler(async (req, res) => {
  const report = await ProjectHealth.findById(req.params.id);
  if (!report) {
    res.status(404);
    throw new Error("Report not found");
  }
  res.json(report);
});

// Update report
export const updateReport = asyncHandler(async (req, res) => {
  const report = await ProjectHealth.findById(req.params.id);
  if (!report) {
    res.status(404);
    throw new Error("Report not found");
  }
  Object.assign(report, req.body);
  await report.save();
  res.json(report);
});

// Delete report
export const deleteReport = asyncHandler(async (req, res) => {
  const report = await ProjectHealth.findById(req.params.id);
  if (!report) {
    res.status(404);
    throw new Error("Report not found");
  }
  await report.remove();
  res.json({ message: "Report deleted" });
});
